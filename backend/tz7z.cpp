// tz7z.cpp - C ABI bridge to the 7-Zip archive engine.
//
// This is deliberately a small, dependency-free bridge.  It links to the real
// 7-Zip shared library (lib7z.dylib / 7z.so) and talks to its COM-style
// interfaces; everything exposed to the application is plain C.
//
// Based on the public-domain-ish 7-Zip Client7z sample, heavily rewritten for
// UTF-8, macOS/POSIX file I/O, safe extraction and a flat C API.

#include "Common/MyWindows.h"
#include "Common/MyInitGuid.h"

/* 7-Zip's headers declare the WINAPI calling convention, which is empty on
   POSIX.  Keep the guard: it must be defined before any 7-Zip header so the
   declarations match the vendored library exactly. */
#ifndef WINAPI
#define WINAPI
#endif
#include "Common/MyCom.h"
#include "Common/MyString.h"
#include "7zip/Common/MultiOutStream.h"
#include "7zip/Archive/Common/MultiStream.h"
#include "Common/UTFConvert.h"
#include "Common/IntToString.h"
#include "7zip/IStream.h"
#include "7zip/ICoder.h"
#include "7zip/Archive/IArchive.h"
#include "7zip/IPassword.h"
#include "7zip/PropID.h"

#include "tz7z.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>
#include <utime.h>
#include <vector>
#include <algorithm>
#include <mutex>
#include <new>
#include <memory>

#ifdef __APPLE__
#include <sys/param.h>
#endif

extern "C" {
HRESULT CreateObject(const GUID *clsid, const GUID *iid, void **outObject);
HRESULT GetNumberOfFormats(UInt32 *numFormats);
HRESULT GetHandlerProperty2(UInt32 index, PROPID propID, PROPVARIANT *value);
}

// Every exported entry point guards its body with these: a C++ exception must
// never unwind through the C ABI into Free Pascal.  Memory exhaustion and any
// unexpected exception are reported as TZ7Z_E_MEMORY (a system error such as
// EIO is normally reported before it can throw).
#define TZ7Z_API_TRY try {
#define TZ7Z_API_CATCH_INT } catch (...) { return TZ7Z_E_MEMORY; }
#define TZ7Z_API_CATCH_VOID } catch (...) { }
#define TZ7Z_API_CATCH_PTR } catch (...) { return 0; }

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------

// Last path component; the whole string when there is no slash.
static AString BaseName(const AString &path)
{
  int slash = path.ReverseFind_PathSepar();
  if (slash < 0)
    return path;
  return path.Mid((unsigned)slash + 1, path.Len() - (unsigned)slash - 1);
}

// "base" + ".001" for a split-volume part.
static AString VolumePath(const AString &base, unsigned index)
{
  char suffix[16];
  snprintf(suffix, sizeof(suffix), ".%03u", index);
  AString path(base);
  path += suffix;
  return path;
}

// A ".001"-style split part?  (Only the last four bytes are inspected, matching
// the convention the engine itself uses for split archives.)
static bool IsSplitPartPath(const AString &path)
{
  return path.Len() >= 4 && strcmp(path.Ptr() + path.Len() - 4, ".001") == 0;
}

// "x.7z.001" -> "x.7z" (the ".001" suffix is four characters, not three: the
// dot is part of the suffix, unlike the old hand-built "base + 001").
static AString SplitPartBase(const AString &path)
{
  AString base(path);
  if (IsSplitPartPath(path))
    base.DeleteFrom(base.Len() - 4);
  return base;
}

// mkstemp-style unique sibling name.  The predictable "path + .tyzip-tmp" the
// bridge used before could be pre-created as a symlink (truncating an arbitrary
// writable file) or collide between two concurrent updates.  mkstemp both picks
// a fresh name and creates the file with O_EXCL, so the reservation is atomic.
static bool CreateUniqueFile(const AString &dir, const AString &stem,
                             AString &path, int &fd)
{
  path.Empty();
  if (!dir.IsEmpty())
  {
    path = dir;
    if (path.Back() != '/')
      path += '/';
  }
  path += stem;
  path += ".tyzip-tmp-XXXXXX";
  std::vector<char> buf((size_t)path.Len() + 1);
  memcpy(&buf[0], path.Ptr(), path.Len());
  buf[path.Len()] = 0;
  fd = mkstemp(&buf[0]);
  if (fd < 0)
    return false;
  path = AString(&buf[0]);
  return true;
}

// 0666 minus the process umask, the permissions fopen("wb+") would have used.
static mode_t DefaultFileMode()
{
  mode_t mask = umask(0);
  umask(mask);
  return (mode_t)(0666 & ~mask);
}

static const UInt32 kUnixAttrib = 0x8000;

/* How far into the file each handler may look for its signature.  8 MB is the
   7-Zip client default; without it some formats refuse to open files whose
   header is not at offset 0. */
static const UInt64 kOpenScanBytes = 1 << 23;

static UString U8(const char *s)
{
  UString out;
  if (s && *s)
  {
    if (!ConvertUTF8ToUnicode(AString(s), out))
      out = UString();
  }
  return out;
}

static AString ToU8(const UString &s)
{
  AString out;
  ConvertUnicodeToUTF8(s, out);
  return out;
}

// Copy at most `limit` bytes of `src` without splitting a UTF-8 sequence.
// Falls back to a byte copy when the input is not valid UTF-8 (a truncated
// character would make the Pascal side see an invalid string).
static size_t Utf8PrefixLength(const char *src, size_t limit)
{
  size_t n = 0;
  while (n < limit && src[n])
  {
    const unsigned char c = (unsigned char)src[n];
    size_t len = 1;
    if ((c & 0x80) == 0)
      len = 1;
    else if ((c & 0xE0) == 0xC0)
      len = 2;
    else if ((c & 0xF0) == 0xE0)
      len = 3;
    else if ((c & 0xF8) == 0xF0)
      len = 4;
    else
      len = 1; // invalid lead byte: keep it, the caller gets the raw bytes
    if (n + len > limit)
      break;
    if (len > 1)
    {
      bool valid = true;
      for (size_t k = 1; k < len; k++)
        if (((unsigned char)src[n + k] & 0xC0) != 0x80)
        {
          valid = false;
          break;
        }
      if (!valid)
        len = 1;
    }
    n += len;
  }
  return n;
}

static void CopyUtf8Truncated(char *dst, size_t cap, const char *src)
{
  if (!dst || cap == 0)
    return;
  if (!src)
    src = "";
  const size_t n = Utf8PrefixLength(src, cap - 1);
  memcpy(dst, src, n);
  dst[n] = 0;
}

static void SetError(char *err, int cap, const char *msg)
{
  if (!err || cap <= 0)
    return;
  if (!msg)
    msg = "";
  CopyUtf8Truncated(err, (size_t)cap, msg);
}

static void SetErrorU(char *err, int cap, const UString &msg)
{
  SetError(err, cap, ToU8(msg));
}

// Every struct crossing the ABI starts with (struct_size, abi_version).  A
// caller built against another revision is rejected before the library writes
// into (or reads past) its struct; the message names both sides so a stale
// libtz7z.dylib next to a newer TyZip is diagnosable.
static bool CheckAbi(uint32_t structSize, uint32_t abiVersion, size_t expected,
                     const char *what, char *err, int errCap)
{
  if (structSize == expected && abiVersion == TZ7Z_ABI_VERSION)
    return true;
  if (err && errCap > 0)
  {
    char msg[256];
    snprintf(msg, sizeof(msg),
             "ABI mismatch for %s: caller passes size %u version %u, "
             "this library expects size %u version %u",
             what, (unsigned)structSize, (unsigned)abiVersion,
             (unsigned)expected, (unsigned)TZ7Z_ABI_VERSION);
    SetError(err, errCap, msg);
  }
  return false;
}


// Optional detailed-progress target shared by the open/extract/update
// callbacks.  The old tz7z_progress_fn and the ABI-v4 sink are dispatched from
// one place, under one mutex: SetCompleted/SetRatioInfo may be called from a
// coder thread, so the sink must never see concurrent calls.
class CProgressTarget
{
public:
  tz7z_progress_fn Legacy;
  void *LegacyUser;
  const tz7z_progress_sink *Sink;
  UInt32 Phase;
  std::mutex Lock;
  UInt64 BytesTotal;
  UInt64 BytesDone;
  UInt64 PackedDone;
  bool PackedKnown;
  UInt32 ItemIndex;
  UInt32 ItemCount;

  CProgressTarget(tz7z_progress_fn legacy, void *legacyUser,
                  const tz7z_progress_sink *sink, UInt32 phase)
    : Legacy(legacy), LegacyUser(legacyUser), Sink(sink), Phase(phase),
      BytesTotal(0), BytesDone(0), PackedDone(0), PackedKnown(false),
      ItemIndex((UInt32)(Int32)-1), ItemCount(0)
  {
  }

  bool Emit(UInt32 event, UInt64 done, UInt64 total, bool packedKnown,
            UInt64 packedDone, UInt32 itemIndex, const char *itemName,
            bool callLegacy)
  {
    std::lock_guard<std::mutex> lock(Lock);
    BytesDone = done;
    BytesTotal = total;
    if (packedKnown)
    {
      PackedDone = packedDone;
      PackedKnown = true;
    }
    if (callLegacy && Legacy)
    {
      if (!Legacy(LegacyUser, done, total))
        return false;
    }
    if (Sink && Sink->fn)
    {
      tz7z_progress_info info;
      memset(&info, 0, sizeof(info));
      info.struct_size = sizeof(info);
      info.abi_version = TZ7Z_ABI_VERSION;
      info.phase = Phase;
      info.event = event;
      info.item_index = itemIndex;
      info.item_count = ItemCount;
      info.index_is_arc = 1;
      info.packed_known = (PackedKnown ? 1 : 0);
      info.bytes_done = BytesDone;
      info.bytes_total = BytesTotal;
      info.packed_done = PackedDone;
      info.item_name = itemName;
      if (!Sink->fn(Sink->user, &info))
        return false;
    }
    return true;
  }

  bool SetTotal(UInt64 total)
  {
    return Emit(TZ7Z_EV_TICK, 0, total, false, 0, ItemIndex, NULL, true);
  }

  bool SetCompleted(UInt64 done)
  {
    return Emit(TZ7Z_EV_TICK, done, BytesTotal, false, 0, ItemIndex, NULL, true);
  }

  bool Item(UInt32 index, const char *name, UInt32 count)
  {
    ItemIndex = index;
    ItemCount = count;
    return Emit(TZ7Z_EV_ITEM, BytesDone, BytesTotal, PackedKnown, PackedDone,
                index, name, false);
  }

  bool ItemDone()
  {
    return Emit(TZ7Z_EV_ITEM_DONE, BytesDone, BytesTotal, PackedKnown,
                PackedDone, ItemIndex, NULL, false);
  }

  bool Ratio(bool packedFromOut, const UInt64 *inSize, const UInt64 *outSize)
  {
    const UInt64 *p = packedFromOut ? outSize : inSize;
    if (!p)
      return true;
    return Emit(TZ7Z_EV_TICK, BytesDone, BytesTotal, true, *p, ItemIndex,
                NULL, false);
  }

  // IArchiveOpenCallback gets two optional counters, neither of which is the
  // byte total the other phases use.  Pass them straight through as the base
  // tick; a NULL counter means "not provided by this handler".
  bool OpenSet(const UInt64 *files, const UInt64 *bytes, bool completed)
  {
    if (files)
      ItemCount = (UInt32)(*files > 0xFFFFFFFFULL ? 0xFFFFFFFFULL : *files);
    UInt64 total = BytesTotal;
    UInt64 done = BytesDone;
    if (completed)
    {
      if (bytes)
        done = *bytes;
    }
    else if (bytes)
      total = *bytes;
    return Emit(TZ7Z_EV_TICK, done, total, false, 0, ItemIndex, NULL, false);
  }
};

static bool CheckProgressSink(const tz7z_progress_sink *sink,
                              char *err, int errCap)
{
  if (!sink)
    return true;
  return CheckAbi(sink->struct_size, sink->abi_version, sizeof(*sink),
                  "tz7z_progress_sink", err, errCap);
}

static void InitProp(PROPVARIANT &p)
{
  memset(&p, 0, sizeof(p));
  p.vt = VT_EMPTY;
}

static void ClearProp(PROPVARIANT &p)
{
  VariantClear(&p);
}

static UInt64 FileTimeToUnix(const FILETIME &ft)
{
  UInt64 v = ((UInt64)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
  if (v < 116444736000000000ULL)
    return 0;
  return (v - 116444736000000000ULL) / 10000000ULL;
}

static FILETIME UnixToFileTime(UInt64 secs)
{
  FILETIME ft;
  UInt64 v = secs * 10000000ULL + 116444736000000000ULL;
  ft.dwLowDateTime = (DWORD)(v & 0xFFFFFFFF);
  ft.dwHighDateTime = (DWORD)(v >> 32);
  return ft;
}

static bool GetPropU64(IInArchive *arc, UInt32 index, PROPID id, UInt64 &value)
{
  PROPVARIANT p;
  InitProp(p);
  HRESULT hr = arc->GetProperty(index, id, &p);
  bool ok = false;
  if (hr == S_OK)
  {
    switch (p.vt)
    {
      case VT_UI1: value = p.bVal; ok = true; break;
      case VT_UI2: value = p.uiVal; ok = true; break;
      case VT_UI4: value = p.ulVal; ok = true; break;
      case VT_UI8: value = p.uhVal.QuadPart; ok = true; break;
      case VT_I1: value = (UInt64)p.cVal; ok = true; break;
      case VT_I2: value = (UInt64)p.iVal; ok = true; break;
      case VT_I4: value = (UInt64)p.lVal; ok = true; break;
      case VT_I8: value = (UInt64)p.hVal.QuadPart; ok = true; break;
      case VT_BOOL: value = p.boolVal ? 1 : 0; ok = true; break;
      default: break;
    }
  }
  ClearProp(p);
  return ok;
}

static bool GetPropBool(IInArchive *arc, UInt32 index, PROPID id, bool def)
{
  UInt64 v = 0;
  if (!GetPropU64(arc, index, id, v))
    return def;
  return v != 0;
}

static UString GetPropStr(IInArchive *arc, UInt32 index, PROPID id)
{
  PROPVARIANT p;
  InitProp(p);
  UString out;
  if (arc->GetProperty(index, id, &p) == S_OK && p.vt == VT_BSTR && p.bstrVal)
    out = UString(p.bstrVal);
  ClearProp(p);
  return out;
}

static bool GetPropFileTime(IInArchive *arc, UInt32 index, PROPID id, UInt64 &unixTime)
{
  PROPVARIANT p;
  InitProp(p);
  bool ok = false;
  if (arc->GetProperty(index, id, &p) == S_OK && p.vt == VT_FILETIME)
  {
    unixTime = FileTimeToUnix(p.filetime);
    ok = true;
  }
  ClearProp(p);
  return ok;
}

// 7-Zip attributes from a POSIX stat.
static UInt32 AttribFromStat(const struct stat &st)
{
  UInt32 a;
  if (S_ISDIR(st.st_mode))
    a = 0x10; // FILE_ATTRIBUTE_DIRECTORY
  else
    a = 0x20; // FILE_ATTRIBUTE_ARCHIVE
  if (!(st.st_mode & S_IWUSR))
    a |= 0x01; // FILE_ATTRIBUTE_READONLY
  a |= kUnixAttrib | ((UInt32)(st.st_mode & 0xFFFF) << 16);
  return a;
}

static bool MakeDirs(const AString &path)
{
  if (path.IsEmpty())
    return false;
  AString p = path;
  // convert backslashes defensively
  for (unsigned i = 0; i < p.Len(); i++)
    if (p[i] == '\\')
      p.ReplaceOneCharAtPos(i, '/');
  unsigned start = 0;
  if (p[0] == '/')
    start = 1;
  for (unsigned i = start; i <= p.Len(); i++)
  {
    if (i == p.Len() || p[i] == '/')
    {
      if (i == start)
        continue;
      AString part = p.Left(i);
      if (mkdir(part.Ptr(), 0755) != 0)
      {
        if (errno != EEXIST)
          return false;
        /* EEXIST is not enough: the component may be a regular file (or a
           dangling link), and continuing only moves the failure to a later
           "cannot create file" for the whole path.  stat() follows links, so a
           directory reached through one is still accepted. */
        struct stat st;
        if (stat(part.Ptr(), &st) != 0 || !S_ISDIR(st.st_mode))
          return false;
      }
      start = i + 1;
      while (start < p.Len() && p[start] == '/')
        start++;
      i = start > 0 ? start - 1 : 0;
    }
  }
  return true;
}

static AString ParentDir(const AString &path)
{
  int pos = path.ReverseFind_PathSepar();
  if (pos < 0)
    return AString(".");
  if (pos == 0)
    return AString("/");
  return path.Left((unsigned)pos);
}

static bool PathExists(const AString &path)
{
  struct stat st;
  return stat(path.Ptr(), &st) == 0;
}

// Build a safe local path: no absolute path, no "..", no drive letters.
static bool SafeRelativePath(const AString &rawIn, AString &out)
{
  AString raw = rawIn;
  for (unsigned i = 0; i < raw.Len(); i++)
    if (raw[i] == '\\')
      raw.ReplaceOneCharAtPos(i, '/');

  out.Empty();
  unsigned pos = 0;
  while (pos <= raw.Len())
  {
    int slash = raw.Find('/', pos);
    unsigned end = (slash < 0) ? raw.Len() : (unsigned)slash;
    AString part = raw.Mid(pos, end - pos);
    if (!part.IsEmpty() && part != ".")
    {
      if (part == "..")
        return false;
      // Reject a Windows drive prefix like "C:".
      if (part.Len() == 2 && part[1] == ':' && part[0] >= 'A' && part[0] <= 'Z')
        return false;
      if (!out.IsEmpty())
        out += '/';
      out += part;
    }
    if (slash < 0)
      break;
    pos = (unsigned)slash + 1;
  }
  return !out.IsEmpty();
}

static bool SafeJoin(const AString &base, const AString &entry, AString &out)
{
  AString rel;
  if (!SafeRelativePath(entry, rel))
    return false;
  out = base;
  if (!out.IsEmpty() && out.Back() != '/')
    out += '/';
  out += rel;
  return true;
}

// ---------------------------------------------------------------------------
// POSIX streams
// ---------------------------------------------------------------------------

class CFileInStream : public IInStream, public CMyUnknownImp
{
  FILE *_f;
  UInt64 _size;
public:
  Z7_COM_UNKNOWN_IMP_1(IInStream)
public:

  CFileInStream() : _f(0), _size(0) {}
  virtual ~CFileInStream() { if (_f) fclose(_f); }

  bool Open(const AString &path)
  {
    _f = fopen(path.Ptr(), "rb");
    if (!_f)
      return false;
    struct stat st;
    if (fstat(fileno(_f), &st) != 0)
      return false;
    _size = (UInt64)st.st_size;
    return true;
  }

  STDMETHOD(Read)(void *data, UInt32 size, UInt32 *processedSize)
  {
    if (processedSize)
      *processedSize = 0;
    if (!_f)
      return E_FAIL;
    size_t n = fread(data, 1, size, _f);
    if (processedSize)
      *processedSize = (UInt32)n;
    if (n < size && ferror(_f))
      return E_FAIL;
    return S_OK;
  }

  STDMETHOD(Seek)(Int64 offset, UInt32 seekOrigin, UInt64 *newPosition)
  {
    if (!_f)
      return E_FAIL;
    int whence = SEEK_SET;
    if (seekOrigin == STREAM_SEEK_CUR) whence = SEEK_CUR;
    else if (seekOrigin == STREAM_SEEK_END) whence = SEEK_END;
    if (fseeko(_f, (off_t)offset, whence) != 0)
      return E_FAIL;
    off_t p = ftello(_f);
    if (p < 0)
      return E_FAIL;
    if (newPosition)
      *newPosition = (UInt64)p;
    return S_OK;
  }
};

class CFileOutStream : public IOutStream, public CMyUnknownImp
{
  FILE *_f;
  UInt64 _written;   // bytes actually accepted by the file
  UInt64 _limit;     // 0 = unlimited; else stop accepting after this many bytes
public:
  Z7_COM_UNKNOWN_IMP_1(IOutStream)
public:

  CFileOutStream() : _f(0), _written(0), _limit(0) {}
  virtual ~CFileOutStream() { Close(); }

  bool Open(const AString &path)
  {
    _f = fopen(path.Ptr(), "wb+");
    if (!_f)
      return false;
    _written = 0;
    return true;
  }

  // Take ownership of an already-open descriptor (mkstemp hands us one so the
  // file name is reserved atomically).
  bool Adopt(FILE *f)
  {
    if (!f)
      return false;
    _f = f;
    _written = 0;
    return true;
  }

  bool IsOpen() const { return _f != NULL; }

  /* Prefix extraction: after maxBytes the stream reports the remaining input as
     consumed but throws it away, so the file on disk is exactly the prefix and
     the decoder is never asked to grow it.  The extract callback stops the
     decode as soon as LimitReached() is set. */
  void SetWriteLimit(UInt64 maxBytes) { _limit = maxBytes; }
  UInt64 Written() const { return _written; }
  bool LimitReached() const { return _limit != 0 && _written >= _limit; }

  // fflush alone is not enough: stdio buffers writes, so a short disk or a file
  // size limit only fails here, and the descriptor must be synced before the
  // temporary file is renamed over the user's archive.  The old tree silently
  // ignored both the flush and the close result.
  bool Close()
  {
    if (!_f)
      return true;
    bool ok = (fflush(_f) == 0);
    if (ok)
    {
      int fd = fileno(_f);
      if (fd >= 0 && fsync(fd) != 0 && errno != EINVAL && errno != ENOTSUP)
        ok = false;
    }
    if (fclose(_f) != 0)
      ok = false;
    _f = 0;
    return ok;
  }

  STDMETHOD(Write)(const void *data, UInt32 size, UInt32 *processedSize)
  {
    if (processedSize)
      *processedSize = 0;
    if (!_f)
      return E_FAIL;
    UInt32 want = size;
    if (_limit != 0)
    {
      const UInt64 remain = (_written < _limit) ? (_limit - _written) : 0;
      if (remain == 0)
      {
        // Prefix complete: pretend the rest was consumed and drop it.
        if (processedSize)
          *processedSize = size;
        return S_OK;
      }
      if ((UInt64)want > remain)
        want = (UInt32)remain;
    }
    size_t n = fwrite(data, 1, want, _f);
    _written += n;
    if (n != want)
    {
      if (processedSize)
        *processedSize = (UInt32)n;
      return E_FAIL;
    }
    if (processedSize)
      *processedSize = size;
    return S_OK;
  }

  STDMETHOD(Seek)(Int64 offset, UInt32 seekOrigin, UInt64 *newPosition)
  {
    if (!_f)
      return E_FAIL;
    int whence = SEEK_SET;
    if (seekOrigin == STREAM_SEEK_CUR) whence = SEEK_CUR;
    else if (seekOrigin == STREAM_SEEK_END) whence = SEEK_END;
    if (fseeko(_f, (off_t)offset, whence) != 0)
      return E_FAIL;
    off_t p = ftello(_f);
    if (p < 0)
      return E_FAIL;
    if (newPosition)
      *newPosition = (UInt64)p;
    return S_OK;
  }

  // Flush first, or buffered bytes would be written after the truncate and
  // make the file longer than the size the engine just set.
  STDMETHOD(SetSize)(UInt64 newSize)
  {
    if (!_f)
      return E_FAIL;
    if (fflush(_f) != 0)
      return E_FAIL;
    off_t cur = ftello(_f);
    if (cur < 0)
      return E_FAIL;
    if (ftruncate(fileno(_f), (off_t)newSize) != 0)
      return E_FAIL;
    off_t pos = ((off_t)newSize < cur) ? (off_t)newSize : cur;
    if (fseeko(_f, pos, SEEK_SET) != 0)
      return E_FAIL;
    return S_OK;
  }
};

// ---------------------------------------------------------------------------
// format table
// ---------------------------------------------------------------------------

struct CFormatInfo
{
  UString name;
  UString ext;
  UString addExt;
  GUID clsid;
  bool update;

  CFormatInfo() : update(false) { memset(&clsid, 0, sizeof(clsid)); }
};

// The format table is process-wide and was previously filled without any
// synchronisation: the preview thread and a job thread could both be inside
// the first load, racing the vector and seeing an empty table.  It is now
// filled exactly once under a mutex; after that it is read-only, so readers
// need no lock.  A failed load is NOT cached: the next caller retries.
static std::mutex g_FormatsMutex;
static std::vector<CFormatInfo> g_Formats;
static bool g_FormatsLoaded = false;

static bool LoadFormats()
{
  std::lock_guard<std::mutex> lock(g_FormatsMutex);
  if (g_FormatsLoaded)
    return !g_Formats.empty();

  UInt32 n = 0;
  if (GetNumberOfFormats(&n) != S_OK)
    return false;

  std::vector<CFormatInfo> loaded;
  for (UInt32 i = 0; i < n; i++)
  {
    CFormatInfo fi;
    PROPVARIANT p;
    InitProp(p);
    if (GetHandlerProperty2(i, NArchive::NHandlerPropID::kClassID, &p) == S_OK &&
        p.vt == VT_BSTR && p.bstrVal && SysStringByteLen(p.bstrVal) >= sizeof(GUID))
    {
      memcpy(&fi.clsid, p.bstrVal, sizeof(GUID));
      ClearProp(p);
      InitProp(p);
      if (GetHandlerProperty2(i, NArchive::NHandlerPropID::kName, &p) == S_OK &&
          p.vt == VT_BSTR && p.bstrVal)
        fi.name = UString(p.bstrVal);
      ClearProp(p);
      InitProp(p);
      if (GetHandlerProperty2(i, NArchive::NHandlerPropID::kExtension, &p) == S_OK &&
          p.vt == VT_BSTR && p.bstrVal)
        fi.ext = UString(p.bstrVal);
      ClearProp(p);
      InitProp(p);
      if (GetHandlerProperty2(i, NArchive::NHandlerPropID::kAddExtension, &p) == S_OK &&
          p.vt == VT_BSTR && p.bstrVal)
        fi.addExt = UString(p.bstrVal);
      ClearProp(p);
      InitProp(p);
      if (GetHandlerProperty2(i, NArchive::NHandlerPropID::kUpdate, &p) == S_OK &&
          p.vt == VT_BOOL)
        fi.update = (p.boolVal != 0);
      ClearProp(p);

      if (!fi.name.IsEmpty())
        loaded.push_back(fi);
    }
    else
      ClearProp(p);
  }
  if (loaded.empty())
    return false;
  g_Formats.swap(loaded);
  g_FormatsLoaded = true;
  return true;
}

static bool ExtListContains(const UString &extList, const AString &extLower)
{
  AString list = ToU8(extList);
  list.MakeLower_Ascii();
  unsigned pos = 0;
  while (pos <= list.Len())
  {
    int dot = list.Find('.', pos);
    unsigned end = (dot < 0) ? list.Len() : (unsigned)dot;
    AString e = list.Mid(pos, end - pos);
    if (e == extLower)
      return true;
    if (dot < 0)
      break;
    pos = (unsigned)dot + 1;
  }
  return false;
}

static int FindFormatByExtension(const AString &extLower, bool needUpdate)
{
  if (extLower.IsEmpty())
    return -1;
  // Prefer a handler that can also update.  Extension lists contain dots.
  for (int pass = 0; pass < 2; pass++)
  {
    for (size_t i = 0; i < g_Formats.size(); i++)
    {
      const CFormatInfo &fi = g_Formats[i];
      if (needUpdate && !fi.update)
        continue;
      if (pass == 0)
      {
        if (ExtListContains(fi.ext, extLower))
          return (int)i;
      }
      else if (ExtListContains(fi.addExt, extLower))
        return (int)i;
    }
  }
  return -1;
}

static int FindFormatByName(const AString &name, bool needUpdate)
{
  AString n = name;
  n.MakeLower_Ascii();
  for (size_t i = 0; i < g_Formats.size(); i++)
  {
    AString fn = ToU8(g_Formats[i].name);
    fn.MakeLower_Ascii();
    if (fn == n)
    {
      if (needUpdate && !g_Formats[i].update)
        return -1;
      return (int)i;
    }
  }
  return -1;
}

static AString PathExtensionLower(const AString &path)
{
  AString name = path;
  int slash = name.ReverseFind_PathSepar();
  if (slash >= 0)
    name = name.Mid((unsigned)slash + 1, name.Len() - (unsigned)slash - 1);
  int dot = name.ReverseFind('.');
  if (dot < 0)
    return AString();
  AString e = name.Mid((unsigned)dot + 1, name.Len() - (unsigned)dot - 1);
  e.MakeLower_Ascii();
  return e;
}

// Relative path of `path` below `base` ("/"-separated).  Both are known to
// come from SafeJoin, so the prefix check is only a safety net.
static bool PathRelativeTo(const AString &base, const AString &path, AString &rel)
{
  AString b(base);
  if (!b.IsEmpty() && b.Back() != '/')
    b += '/';
  if (path.Len() <= b.Len())
    return false;
  if (strncmp(path.Ptr(), b.Ptr(), b.Len()) != 0)
    return false;
  rel = path.Mid(b.Len(), path.Len() - b.Len());
  return true;
}

// A stored symbolic link target must not point outside the extraction root:
// extracting "link/file" later would then write through the link to an
// arbitrary place.  Relative targets that stay inside, and the single-file
// mode (which has no archive root), are allowed.
static bool SymLinkTargetIsSafe(const AString &linkPath, const AString &target,
                                const AString &outDir, bool singleMode,
                                AString &why)
{
  if (target.IsEmpty())
  {
    why = "empty symbolic link target";
    return false;
  }
  if (target[0] == '/')
  {
    why = "absolute symbolic link target";
    return false;
  }
  if (singleMode)
    return true;
  AString rel;
  if (!PathRelativeTo(outDir, linkPath, rel))
    return true;
  // Depth of the directory that will contain the link.
  AString dir(rel);
  int slash = dir.ReverseFind_PathSepar();
  if (slash < 0)
    dir.Empty();
  else
    dir = dir.Left((unsigned)slash);
  unsigned depth = 0;
  unsigned pos = 0;
  while (pos <= dir.Len())
  {
    int s = dir.Find('/', pos);
    unsigned end = (s < 0) ? dir.Len() : (unsigned)s;
    AString part = dir.Mid(pos, end - pos);
    if (!part.IsEmpty() && part != ".")
      depth++;
    if (s < 0)
      break;
    pos = (unsigned)s + 1;
  }
  // Replay the target's components.
  pos = 0;
  while (pos <= target.Len())
  {
    int s = target.Find('/', pos);
    unsigned end = (s < 0) ? target.Len() : (unsigned)s;
    AString part = target.Mid(pos, end - pos);
    if (!part.IsEmpty() && part != ".")
    {
      if (part == "..")
      {
        if (depth == 0)
        {
          why = "symbolic link target escapes the extraction directory";
          return false;
        }
        depth--;
      }
      else
        depth++;
    }
    if (s < 0)
      break;
    pos = (unsigned)s + 1;
  }
  return true;
}

static bool CreateSymLinkAt(const AString &path, const AString &target, AString &err)
{
  if (unlink(path.Ptr()) != 0 && errno != ENOENT)
  {
    err = "cannot replace the existing path with a symbolic link: ";
    err += path;
    return false;
  }
  if (symlink(target.Ptr(), path.Ptr()) != 0)
  {
    err = "cannot create symbolic link: ";
    err += path;
    return false;
  }
  return true;
}

static bool CreateHardLinkAt(const AString &path, const AString &target, AString &err)
{
  if (unlink(path.Ptr()) != 0 && errno != ENOENT)
  {
    err = "cannot replace the existing path with a hard link: ";
    err += path;
    return false;
  }
  if (link(target.Ptr(), path.Ptr()) != 0)
  {
    err = "cannot create hard link: ";
    err += path;
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// callbacks
// ---------------------------------------------------------------------------

class COpenCallback : public IArchiveOpenCallback,
                      public ICryptoGetTextPassword,
                      public CMyUnknownImp
{
public:
  Z7_COM_UNKNOWN_IMP_2(IArchiveOpenCallback, ICryptoGetTextPassword)
public:

  bool PasswordDefined;
  bool PasswordRequested;
  UString Password;
  CProgressTarget *Target;

  COpenCallback() : PasswordDefined(false), PasswordRequested(false), Target(NULL) {}

  STDMETHOD(SetTotal)(const UInt64 *files, const UInt64 *bytes)
  {
    if (Target && !Target->OpenSet(files, bytes, false))
      return E_ABORT;
    return S_OK;
  }
  STDMETHOD(SetCompleted)(const UInt64 *files, const UInt64 *bytes)
  {
    if (Target && !Target->OpenSet(files, bytes, true))
      return E_ABORT;
    return S_OK;
  }

  STDMETHOD(CryptoGetTextPassword)(BSTR *password)
  {
    PasswordRequested = true;
    if (!PasswordDefined)
      return E_ABORT;
    return StringToBstr(Password, password);
  }
};

static const char *kResultText(int r)
{
  switch (r)
  {
    case NArchive::NExtract::NOperationResult::kOK: return "";
    case NArchive::NExtract::NOperationResult::kUnsupportedMethod: return "unsupported method";
    case NArchive::NExtract::NOperationResult::kDataError: return "data error";
    case NArchive::NExtract::NOperationResult::kCRCError: return "CRC error";
    case NArchive::NExtract::NOperationResult::kUnavailable: return "unavailable data";
    case NArchive::NExtract::NOperationResult::kUnexpectedEnd: return "unexpected end of data";
    case NArchive::NExtract::NOperationResult::kDataAfterEnd: return "data after end";
    case NArchive::NExtract::NOperationResult::kIsNotArc: return "not an archive";
    case NArchive::NExtract::NOperationResult::kHeadersError: return "headers error";
    case NArchive::NExtract::NOperationResult::kWrongPassword: return "wrong password";
    default: return "operation failed";
  }
}

class CExtractCallback : public IArchiveExtractCallback,
                         public ICryptoGetTextPassword,
                         public ICompressProgressInfo,
                         public CMyUnknownImp
{
  CMyComPtr<IInArchive> _arc;
  AString _outDir;
  AString _singlePath;
  bool _singleMode;
  bool _testMode;
  bool _passwordDefined;
  bool _passwordRequested;
  UString _password;
  CProgressTarget *_target;
  UInt32 _itemCount;
  UInt32 _currentIndex;

  // Entry names captured from the archive BEFORE extraction starts. The gzip
  // and bzip2 handlers answer kpidPath when GetProperty is called on the
  // archive, but not from inside the extract callback, where the property comes
  // back empty -- which made every single-stream extraction land in a file
  // called "[Content]" instead of the name stored in the stream.
  std::vector<UString> _names;

  AString _currentDiskPath;
  bool _currentIsDir;
  bool _currentIsLink;
  UInt32 _currentAttrib;
  bool _currentAttribDefined;
  UInt64 _currentMTime;
  bool _currentMTimeDefined;
  UString _currentSymLink;
  UString _currentHardLink;

  struct CLinkPair
  {
    AString Path;
    AString Target;
  };
  // Hard links can point at an entry that is extracted later, so they are
  // created after the extract loop instead of failing on a missing target.
  std::vector<CLinkPair> _pendingHardLinks;

  CMyComPtr<ISequentialOutStream> _outStreamKeep;
  CFileOutStream *_outFile;

  UInt64 _prefixLimit;   // 0 = full extraction
  bool _prefixReached;
  int _result;
  bool _cancelled;
  AString _error;

public:
  Z7_COM_UNKNOWN_IMP_3(IArchiveExtractCallback, ICryptoGetTextPassword,
                       ICompressProgressInfo)
public:

  // Read every entry's name from the archive itself, before extraction starts.
  void CacheNames(UInt32 count)
  {
    _names.clear();
    _names.resize(count);
    for (UInt32 i = 0; i < count; i++)
      _names[i] = GetPropStr(_arc, i, kpidPath);
  }

  CExtractCallback(IInArchive *arc, const AString &outDir,
                   const AString &singlePath, bool singleMode, bool testMode,
                   const UString &password, bool passwordDefined,
                   CProgressTarget *target, UInt64 prefixLimit)
    : _arc(arc), _outDir(outDir), _singlePath(singlePath),
      _singleMode(singleMode), _testMode(testMode),
      _password(password), _passwordDefined(passwordDefined),
      _passwordRequested(false), _target(target), _itemCount(0), _currentIndex(0),
      _prefixLimit(prefixLimit), _prefixReached(false),
      _currentIsDir(false), _currentIsLink(false), _currentAttrib(0),
      _currentAttribDefined(false), _currentMTime(0), _currentMTimeDefined(false),
      _outFile(0), _result(TZ7Z_OK), _cancelled(false)
  {
    UInt32 n = 0;
    if (_arc && _arc->GetNumberOfItems(&n) == S_OK)
      _itemCount = n;
  }

  virtual ~CExtractCallback()
  {
    /* The output stream is owned by _outStreamKeep and closed by its own
       destructor; do not touch the raw alias here. */
  }

  int Result() const { return _result; }
  bool Cancelled() const { return _cancelled; }
  const AString &Error() const { return _error; }

  bool PasswordRequested() const { return _passwordRequested; }
  bool PrefixReached() const { return _prefixReached; }

  /* Close the file that received a prefix and make sure everything reached it.
     Called instead of SetOperationResult when the decode was aborted because
     the prefix is complete. */
  bool FinishPrefix()
  {
    if (_outFile)
    {
      if (!_outFile->Close())
      {
        AString msg;
        msg = "cannot write file: ";
        msg += _currentDiskPath;
        SetFirstError(TZ7Z_E_IO, msg);
      }
      _outFile = 0;
    }
    _outStreamKeep.Release();
    return _result == TZ7Z_OK;
  }

  // Create the deferred hard links after a successful extraction pass.
  bool CreatePendingHardLinks()
  {
    for (size_t i = 0; i < _pendingHardLinks.size(); i++)
    {
      if (!CreateHardLinkAt(_pendingHardLinks[i].Path, _pendingHardLinks[i].Target, _error))
      {
        SetFirstError(TZ7Z_E_IO, _error);
        return false;
      }
    }
    _pendingHardLinks.clear();
    return true;
  }

  STDMETHOD(SetTotal)(UInt64 total)
  {
    if (_target && !_target->SetTotal(total))
    {
      _cancelled = true;
      return E_ABORT;
    }
    return S_OK;
  }

  STDMETHOD(SetCompleted)(const UInt64 *completeValue)
  {
    if (_prefixLimit != 0 && _outFile && _outFile->LimitReached())
    {
      /* The requested prefix is on disk; abort the decode.  This is not a user
         cancel: _cancelled stays false and ExtractInternal turns it into
         success. */
      _prefixReached = true;
      return E_ABORT;
    }
    if (_target && completeValue && !_target->SetCompleted(*completeValue))
    {
      _cancelled = true;
      return E_ABORT;
    }
    return S_OK;
  }

  STDMETHOD(SetRatioInfo)(const UInt64 *inSize, const UInt64 *outSize)
  {
    // For extraction the consumed packed bytes are the input side.  In a solid
    // block this is block-level, not entry-level (see
    // docs/research/7zip-progress-callbacks.md).
    if (_target && !_target->Ratio(false, inSize, outSize))
    {
      _cancelled = true;
      return E_ABORT;
    }
    return S_OK;
  }

  STDMETHOD(GetStream)(UInt32 index, ISequentialOutStream **outStream, Int32 askExtractMode)
  {
    _outStreamKeep.Release();
    _outFile = 0;
    *outStream = 0;
    _currentDiskPath.Empty();
    _currentIsDir = false;
    _currentIsLink = false;
    _currentAttribDefined = false;
    _currentMTimeDefined = false;
    _currentSymLink.Empty();
    _currentHardLink.Empty();

    if (_cancelled)
      return E_ABORT;

    UString name;
    if (index < _names.size())
      name = _names[index];
    if (name.IsEmpty())
      name = GetPropStr(_arc, index, kpidPath);
    if (name.IsEmpty())
      name = L"[Content]";
    AString utf8Name = ToU8(name);
    _currentIndex = index;
    if (_target && !_target->Item(index, utf8Name.Ptr(), _itemCount))
    {
      _cancelled = true;
      return E_ABORT;
    }

    if (askExtractMode != NArchive::NExtract::NAskMode::kExtract)
      return S_OK;

    UInt64 attrib = 0;
    if (GetPropU64(_arc, index, kpidAttrib, attrib))
    {
      _currentAttrib = (UInt32)attrib;
      _currentAttribDefined = true;
    }
    _currentIsDir = GetPropBool(_arc, index, kpidIsDir, false);

    UInt64 mt = 0;
    if (GetPropFileTime(_arc, index, kpidMTime, mt))
    {
      _currentMTime = mt;
      _currentMTimeDefined = true;
    }

    { /* tar/cpio/rar store links as references, not as data.  Without these the
         "link" was extracted as a regular file whose contents were its target. */
      PROPVARIANT p;
      InitProp(p);
      if (_arc->GetProperty(index, kpidSymLink, &p) == S_OK && p.vt == VT_BSTR && p.bstrVal)
        _currentSymLink.SetFromBstr(p.bstrVal);
      ClearProp(p);
      InitProp(p);
      if (_arc->GetProperty(index, kpidHardLink, &p) == S_OK && p.vt == VT_BSTR && p.bstrVal)
        _currentHardLink.SetFromBstr(p.bstrVal);
      ClearProp(p);
    }

    if (_singleMode)
    {
      if (_testMode)
        return S_OK;
      _currentDiskPath = _singlePath;
    }
    else
    {
      AString safe;
      if (!SafeJoin(_outDir, utf8Name, safe))
      {
        _error = "unsafe archive path: ";
        _error += utf8Name;
        _result = TZ7Z_E_EXTRACT;
        return E_FAIL;
      }
      _currentDiskPath = safe;
    }

    if (_testMode)
      return S_OK;

    if (!_currentSymLink.IsEmpty())
    {
      AString linkTarget = ToU8(_currentSymLink);
      AString why;
      if (!SymLinkTargetIsSafe(_currentDiskPath, linkTarget, _outDir, _singleMode, why))
      {
        _error = "unsafe symbolic link (";
        _error += why;
        _error += "): ";
        _error += utf8Name;
        _result = TZ7Z_E_EXTRACT;
        return E_FAIL;
      }
      AString parent = ParentDir(_currentDiskPath);
      if (!MakeDirs(parent))
      {
        _error = "cannot create directory: ";
        _error += parent;
        _result = TZ7Z_E_IO;
        return E_FAIL;
      }
      _currentIsLink = true;
      if (!CreateSymLinkAt(_currentDiskPath, linkTarget, _error))
      {
        _result = TZ7Z_E_IO;
        return E_FAIL;
      }
      return S_OK;
    }

    if (!_currentHardLink.IsEmpty())
    {
      if (_singleMode)
      {
        _error = "cannot extract a hard link on its own: ";
        _error += utf8Name;
        _result = TZ7Z_E_EXTRACT;
        return E_FAIL;
      }
      AString hardTarget;
      if (!SafeJoin(_outDir, ToU8(_currentHardLink), hardTarget))
      {
        _error = "unsafe hard link target: ";
        _error += ToU8(_currentHardLink);
        _result = TZ7Z_E_EXTRACT;
        return E_FAIL;
      }
      AString parent = ParentDir(_currentDiskPath);
      if (!MakeDirs(parent))
      {
        _error = "cannot create directory: ";
        _error += parent;
        _result = TZ7Z_E_IO;
        return E_FAIL;
      }
      CLinkPair pair;
      pair.Path = _currentDiskPath;
      pair.Target = hardTarget;
      _pendingHardLinks.push_back(pair);
      _currentIsLink = true;
      return S_OK;
    }

    if (_currentIsDir)
    {
      AString dir = _currentDiskPath;
      if (!MakeDirs(dir))
      {
        _error = "cannot create directory: ";
        _error += dir;
        _result = TZ7Z_E_IO;
        return E_FAIL;
      }
      return S_OK;
    }

    AString parent = ParentDir(_currentDiskPath);
    if (!MakeDirs(parent))
    {
      _error = "cannot create directory: ";
      _error += parent;
      _result = TZ7Z_E_IO;
      return E_FAIL;
    }

    CFileOutStream *fs = new CFileOutStream();
    if (!fs->Open(_currentDiskPath))
    {
      delete fs;
      _error = "cannot create file: ";
      _error += _currentDiskPath;
      _result = TZ7Z_E_IO;
      return E_FAIL;
    }
    if (_prefixLimit != 0)
      fs->SetWriteLimit(_prefixLimit);
    _outFile = fs;
    _outStreamKeep = fs; // keep one reference while the callback lives
    ISequentialOutStream *handed = fs;
    handed->AddRef();    // hand one reference to 7-Zip; it releases it
    *outStream = handed;
    return S_OK;
  }

  STDMETHOD(PrepareOperation)(Int32) { return S_OK; }

  /* Keep the FIRST failure: 7-Zip keeps calling SetOperationResult for the
     remaining entries, and overwriting the code/text on every one used to make
     the user see an arbitrary later error (possibly of a different kind). */
  void SetFirstError(int code, const AString &msg)
  {
    if (_result == TZ7Z_OK)
    {
      _result = code;
      _error = msg;
    }
  }

  STDMETHOD(SetOperationResult)(Int32 resultEOperationResult)
  {
    if (_target && !_target->ItemDone())
    {
      _cancelled = true;
      return E_ABORT;
    }
    /* A prefix extraction was stopped on purpose; 7-Zip may still report the
       truncated operation, which is not an error. */
    if (_prefixReached)
    {
      FinishPrefix();
      return S_OK;
    }
    if (_outFile)
    {
      if (!_outFile->Close())
      {
        AString msg;
        msg = "cannot write file: ";
        msg += _currentDiskPath;
        SetFirstError(TZ7Z_E_IO, msg);
      }
      _outFile = 0;
    }

    if (resultEOperationResult != NArchive::NExtract::NOperationResult::kOK)
    {
      const int code =
          (resultEOperationResult == NArchive::NExtract::NOperationResult::kWrongPassword)
              ? TZ7Z_E_PASSWORD : TZ7Z_E_EXTRACT;
      AString msg;
      msg = kResultText(resultEOperationResult);
      if (!_currentDiskPath.IsEmpty())
      {
        msg += ": ";
        msg += _currentDiskPath;
      }
      SetFirstError(code, msg);
      return S_OK; // keep extracting, report the first error at the end
    }

    /* A link has no meaningful mode/time of its own: chmod'ing or utime'ing it
       would follow the link and touch its target. */
    if (!_testMode && !_currentIsLink && _currentAttribDefined && !_currentIsDir &&
        (_currentAttrib & kUnixAttrib))
    {
      mode_t mode = (mode_t)((_currentAttrib >> 16) & 0777);
      if (mode)
        chmod(_currentDiskPath.Ptr(), mode);
    }
    if (!_testMode && !_currentIsLink && _currentMTimeDefined && _currentMTime > 0)
    {
      struct utimbuf ut;
      ut.actime = (time_t)_currentMTime;
      ut.modtime = (time_t)_currentMTime;
      utime(_currentDiskPath.Ptr(), &ut);
    }
    return S_OK;
  }

  STDMETHOD(CryptoGetTextPassword)(BSTR *password)
  {
    _passwordRequested = true;
    if (!_passwordDefined)
      return E_ABORT;
    return StringToBstr(_password, password);
  }
};

// ---------------------------------------------------------------------------
// update callback (create and modify)
// ---------------------------------------------------------------------------

struct CCreateItem
{
  AString DiskPath;
  UString ArcPath;
  bool IsDir;
  bool NewData;
  int OldIndex;
  UInt64 Size;
  UInt32 Attrib;
  FILETIME CTime, ATime, MTime;

  CCreateItem()
    : IsDir(false), NewData(true), OldIndex(-1), Size(0), Attrib(0)
  {
    memset(&CTime, 0, sizeof(CTime));
    memset(&ATime, 0, sizeof(ATime));
    memset(&MTime, 0, sizeof(MTime));
  }
};

class CUpdateCallback : public IArchiveUpdateCallback2,
                        public ICryptoGetTextPassword2,
                        public ICryptoGetTextPassword,
                        public ICompressProgressInfo,
                        public IArchiveUpdateCallbackFile,
                        public CMyUnknownImp
{
  std::vector<CCreateItem> *_items;
  bool _passwordDefined;
  UString _password;
  CProgressTarget *_target;
  UInt32 _lastItem;
  int _result;
  bool _cancelled;

public:
  Z7_COM_UNKNOWN_IMP_5(IArchiveUpdateCallback2, ICryptoGetTextPassword2,
                       ICryptoGetTextPassword, ICompressProgressInfo,
                       IArchiveUpdateCallbackFile)
public:

  CUpdateCallback(std::vector<CCreateItem> *items, const UString &password,
                  bool passwordDefined, CProgressTarget *target)
    : _items(items), _password(password), _passwordDefined(passwordDefined),
      _target(target), _lastItem((UInt32)(Int32)-1),
      _result(TZ7Z_OK), _cancelled(false)
  {
  }

  int Result() const { return _result; }
  bool Cancelled() const { return _cancelled; }

  STDMETHOD(SetTotal)(UInt64 total)
  {
    if (_target && !_target->SetTotal(total))
    {
      _cancelled = true;
      return E_ABORT;
    }
    return S_OK;
  }

  STDMETHOD(SetCompleted)(const UInt64 *completeValue)
  {
    if (_target && completeValue && !_target->SetCompleted(*completeValue))
    {
      _cancelled = true;
      return E_ABORT;
    }
    return S_OK;
  }

  STDMETHOD(SetRatioInfo)(const UInt64 *inSize, const UInt64 *outSize)
  {
    // Creation has the packed output on the outSize side.
    if (_target && !_target->Ratio(true, inSize, outSize))
    {
      _cancelled = true;
      return E_ABORT;
    }
    return S_OK;
  }

  STDMETHOD(GetUpdateItemInfo)(UInt32 index, Int32 *newData, Int32 *newProps,
                               UInt32 *indexInArchive)
  {
    if (index >= _items->size())
      return E_INVALIDARG;
    const CCreateItem &it = (*_items)[index];
    if (newData) *newData = it.NewData ? 1 : 0;
    if (newProps) *newProps = it.NewData ? 1 : 0;
    if (indexInArchive)
      *indexInArchive = it.NewData ? (UInt32)(Int32)-1 : (UInt32)it.OldIndex;
    return S_OK;
  }

  STDMETHOD(GetProperty)(UInt32 index, PROPID propID, PROPVARIANT *value)
  {
    if (index >= _items->size())
      return E_INVALIDARG;
    const CCreateItem &it = (*_items)[index];
    InitProp(*value);
    switch (propID)
    {
      case kpidPath:
        value->vt = VT_BSTR;
        value->bstrVal = SysAllocString(it.ArcPath);
        if (!value->bstrVal) return E_OUTOFMEMORY;
        break;
      case kpidIsDir:
        value->vt = VT_BOOL;
        value->boolVal = it.IsDir ? VARIANT_TRUE : VARIANT_FALSE;
        break;
      case kpidSize:
        value->vt = VT_UI8;
        value->uhVal.QuadPart = it.IsDir ? 0 : it.Size;
        break;
      case kpidAttrib:
        value->vt = VT_UI4;
        value->ulVal = it.Attrib;
        break;
      case kpidCTime:
        value->vt = VT_FILETIME;
        value->filetime = it.CTime;
        break;
      case kpidATime:
        value->vt = VT_FILETIME;
        value->filetime = it.ATime;
        break;
      case kpidMTime:
        value->vt = VT_FILETIME;
        value->filetime = it.MTime;
        break;
      case kpidIsAnti:
        value->vt = VT_BOOL;
        value->boolVal = VARIANT_FALSE;
        break;
      default:
        break;
    }
    return S_OK;
  }

  STDMETHOD(GetStream)(UInt32 index, ISequentialInStream **inStream)
  {
    *inStream = 0;
    if (index >= _items->size())
      return E_INVALIDARG;
    const CCreateItem &it = (*_items)[index];
    if (_target && index != _lastItem)
    {
      _lastItem = index;
      AString name = ToU8(it.ArcPath);
      if (!_target->Item(index, name.Ptr(), (UInt32)_items->size()))
      {
        _cancelled = true;
        return E_ABORT;
      }
    }
    if (!it.NewData)
      return S_OK;
    if (it.IsDir)
      return S_OK;
    if (_cancelled)
      return E_ABORT;
    CFileInStream *s = new CFileInStream();
    if (!s->Open(it.DiskPath))
    {
      delete s;
      _result = TZ7Z_E_IO;
      return E_FAIL;
    }
    CMyComPtr<ISequentialInStream> seq = s;
    *inStream = seq.Detach();
    return S_OK;
  }

  STDMETHOD(GetStream2)(UInt32 index, ISequentialInStream **inStream,
                        UInt32)
  {
    return GetStream(index, inStream);
  }

  STDMETHOD(ReportOperation)(UInt32, UInt32, UInt32)
  {
    return S_OK;
  }

  STDMETHOD(SetOperationResult)(Int32)
  {
    if (_target && !_target->ItemDone())
    {
      _cancelled = true;
      return E_ABORT;
    }
    return S_OK;
  }

  // Split archives are produced by CMultiOutStream on the output side (both
  // create and modify).  The per-volume callback path only ever answered
  // S_FALSE (volume size was always 0), so it is kept as a no-op for the
  // interface contract rather than a second, dead implementation.
  STDMETHOD(GetVolumeSize)(UInt32, UInt64 *) { return S_FALSE; }
  STDMETHOD(GetVolumeStream)(UInt32, ISequentialOutStream **volumeStream)
  {
    if (volumeStream)
      *volumeStream = 0;
    return S_FALSE;
  }

  STDMETHOD(CryptoGetTextPassword2)(Int32 *passwordIsDefined, BSTR *password)
  {
    *passwordIsDefined = _passwordDefined ? 1 : 0;
    return StringToBstr(_passwordDefined ? _password : UString(), password);
  }

  STDMETHOD(CryptoGetTextPassword)(BSTR *password)
  {
    if (!_passwordDefined)
      return E_ABORT;
    return StringToBstr(_password, password);
  }
};

// ---------------------------------------------------------------------------
// archive handle
// ---------------------------------------------------------------------------

struct tz7z_archive
{
  CMyComPtr<IInArchive> Arc;
  AString Path;
  AString FormatName;
  UString Password;
  bool PasswordDefined;
  bool HasEncrypted;
  bool CanUpdate;
  // Opened from a ".001" split set.  A rewrite cannot reconstruct such a set
  // without a volume size from the caller, so modify refuses instead of
  // collapsing it into a single file and orphaning the old .002... parts.
  bool IsSplit;
  // The ZIP name code page this handle was opened with (0 = engine default),
  // for diagnostics and future callers; decoding itself lives in 7-Zip.
  uint32_t NameCodepage;
  GUID Clsid;

  tz7z_archive()
    : PasswordDefined(false), HasEncrypted(false), CanUpdate(false),
      IsSplit(false), NameCodepage(0)
  {
    memset(&Clsid, 0, sizeof(Clsid));
  }
};

static bool OpenInputVolumes(const AString &path, CMyComPtr<IInStream> &result)
{
  result = 0;
  if (!IsSplitPartPath(path))
    return false;

  CMultiStream *ms = new CMultiStream();
  AString base = SplitPartBase(path);
  for (unsigned i = 1; i < 1000; i++)
  {
    AString vp = VolumePath(base, i);
    struct stat st;
    if (stat(vp.Ptr(), &st) != 0 || !S_ISREG(st.st_mode))
      break;
    CFileInStream *fs = new CFileInStream();
    if (!fs->Open(vp))
    {
      delete fs;
      break;
    }
    CMultiStream::CSubStreamInfo s;
    s.Stream = fs;
    s.Size = (UInt64)st.st_size;
    ms->Streams.Add(s);
  }
  if (ms->Streams.Size() == 0)
  {
    delete ms;
    return false;
  }
  ms->Init();
  result = ms;
  return true;
}

static int OpenArchiveInternal(const AString &path, const UString &password,
                               bool passwordDefined, tz7z_archive **out,
                               char *err, int errCap,
                               const tz7z_progress_sink *sink)
{
  if (!out)
    return TZ7Z_E_ARG;
  *out = 0;
  if (!LoadFormats())
  {
    SetError(err, errCap, "cannot load 7-Zip engine format table");
    return TZ7Z_E_OPEN;
  }

  AString ext = PathExtensionLower(path);
  int preferred = FindFormatByExtension(ext, false);

  std::vector<int> order;
  if (preferred >= 0)
    order.push_back(preferred);
  for (int i = 0; i < (int)g_Formats.size(); i++)
    if (i != preferred)
      order.push_back(i);

  for (size_t attempt = 0; attempt < order.size(); attempt++)
  {
    int fi = order[attempt];

    CMyComPtr<IInStream> stream;
    bool multi = OpenInputVolumes(path, stream);
    if (!multi)
    {
      CFileInStream *fs = new CFileInStream();
      if (!fs->Open(path))
      {
        delete fs;
        SetError(err, errCap, "cannot open archive file");
        return TZ7Z_E_IO;
      }
      stream = fs;
    }

    IInArchive *raw = 0;
    HRESULT hr = CreateObject(&g_Formats[fi].clsid, &IID_IInArchive, (void **)&raw);
    if (hr != S_OK || !raw)
      continue;
    CMyComPtr<IInArchive> arc;
    arc.Attach(raw);

    CProgressTarget progressTarget(NULL, NULL, sink, TZ7Z_PH_OPEN);
    COpenCallback *oc = new COpenCallback();
    CMyComPtr<IArchiveOpenCallback> openCb = oc;
    oc->Password = password;
    oc->PasswordDefined = passwordDefined;
    oc->Target = &progressTarget;

    /* How far into the file each handler may look for its signature.  8 MB is
       the 7-Zip client default; without it some formats refuse to open small
       files whose header is not at offset 0. */
    UInt64 scanSize = kOpenScanBytes;
    hr = arc->Open(stream, &scanSize, openCb);
    if (hr == S_OK)
    {
      tz7z_archive *a = new tz7z_archive();
      a->Arc = arc;
      a->Path = path;
      a->FormatName = ToU8(g_Formats[fi].name);
      a->Password = password;
      a->PasswordDefined = passwordDefined;
      a->CanUpdate = g_Formats[fi].update;
      a->IsSplit = multi && IsSplitPartPath(path);
      a->Clsid = g_Formats[fi].clsid;

      UInt32 n = 0;
      arc->GetNumberOfItems(&n);
      for (UInt32 i = 0; i < n && !a->HasEncrypted; i++)
        if (GetPropBool(arc, i, kpidEncrypted, false))
          a->HasEncrypted = true;

      *out = a;
      return TZ7Z_OK;
    }

    /* A handler only asks for a password when it found an encrypted archive:
       whether the caller supplied one or not, failing after that point is a
       password problem, not "this file is not an archive".  The old code only
       reported it when no password was passed, so a wrong password on a 7z with
       encrypted headers looked like a foreign file.  Handlers that never ask
       for a password keep returning TZ7Z_E_NOT_ARCHIVE. */
    if (oc->PasswordRequested)
    {
      SetError(err, errCap, passwordDefined ? "wrong password" : "password required");
      return TZ7Z_E_PASSWORD;
    }
  }

  SetError(err, errCap, "not a supported archive");
  return TZ7Z_E_NOT_ARCHIVE;
}

// ---------------------------------------------------------------------------
// public API
// ---------------------------------------------------------------------------

uint32_t tz7z_abi_version(void)
{
  return TZ7Z_ABI_VERSION;
}

// Minimal JSON string escaping: the format table is engine-provided ASCII today,
// but a quote or control character in a name must not produce broken JSON.
static AString JsonEscape(const AString &in)
{
  AString out;
  for (unsigned i = 0; i < in.Len(); i++)
  {
    const unsigned char c = (unsigned char)in[i];
    switch (c)
    {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20)
        {
          char esc[8];
          snprintf(esc, sizeof(esc), "\\u%04x", (unsigned)c);
          out += esc;
        }
        else
          out += (char)c;
        break;
    }
  }
  return out;
}

int tz7z_format_json(char *buffer, int capacity)
{
  TZ7Z_API_TRY
  if (!LoadFormats())
  {
    if (buffer && capacity > 0) buffer[0] = 0;
    /* -1, not 1: "the engine table failed to load" must be distinguishable from
       "the table is empty" by the caller. */
    return -1;
  }
  AString json("[");
  for (size_t i = 0; i < g_Formats.size(); i++)
  {
    if (i) json += ",";
    json += "{\"name\":\"";
    AString n = JsonEscape(ToU8(g_Formats[i].name));
    AString e = JsonEscape(ToU8(g_Formats[i].ext));
    AString ae = JsonEscape(ToU8(g_Formats[i].addExt));
    json += n;
    json += "\",\"ext\":\"";
    json += e;
    json += "\",\"addext\":\"";
    json += ae;
    json += "\",\"update\":";
    json += g_Formats[i].update ? "true" : "false";
    json += "}";
  }
  json += "]";
  if (buffer && capacity > 0)
  {
    unsigned copy = (unsigned)capacity - 1;
    if (copy > json.Len()) copy = json.Len();
    memcpy(buffer, json.Ptr(), copy);
    buffer[copy] = 0;
  }
  return (int)json.Len() + 1;
  TZ7Z_API_CATCH_INT
}

int tz7z_open(const char *path, const char *password,
              tz7z_archive **out_archive,
              char *err, int err_capacity)
{
  TZ7Z_API_TRY
  if (!path || !*path || !out_archive)
  {
    SetError(err, err_capacity, "invalid argument");
    return TZ7Z_E_ARG;
  }
  AString p(path);
  UString pw = U8(password);
  bool defined = password && *password;
  return OpenArchiveInternal(p, pw, defined, out_archive, err, err_capacity,
                             NULL);
  TZ7Z_API_CATCH_INT
}

int tz7z_open_ex(const char *path, const char *password,
                 const tz7z_progress_sink *sink,
                 tz7z_archive **out_archive,
                 char *err, int err_capacity)
{
  TZ7Z_API_TRY
  if (!CheckProgressSink(sink, err, err_capacity))
    return TZ7Z_E_ARG;
  if (!path || !*path || !out_archive)
  {
    SetError(err, err_capacity, "invalid argument");
    return TZ7Z_E_ARG;
  }
  AString p(path);
  UString pw = U8(password);
  bool defined = password && *password;
  return OpenArchiveInternal(p, pw, defined, out_archive, err, err_capacity,
                             sink);
  TZ7Z_API_CATCH_INT
}

void tz7z_close(tz7z_archive *archive)
{
  TZ7Z_API_TRY
  delete archive;
  TZ7Z_API_CATCH_VOID
}

int tz7z_entry_count(tz7z_archive *archive)
{
  TZ7Z_API_TRY
  if (!archive) return 0;
  UInt32 n = 0;
  archive->Arc->GetNumberOfItems(&n);
  return (int)n;
  TZ7Z_API_CATCH_INT
}

const char *tz7z_format_name(tz7z_archive *archive)
{
  TZ7Z_API_TRY
  if (!archive) return "";
  /* The old version copied into a function-local static AString, so two
     threads opening different formats corrupted each other's buffer.  The
     handle owns the name; the pointer is valid until tz7z_close. */
  return archive->FormatName.Ptr();
  TZ7Z_API_CATCH_PTR
}

int tz7z_has_encrypted(tz7z_archive *archive)
{
  TZ7Z_API_TRY
  return archive && archive->HasEncrypted ? 1 : 0;
  TZ7Z_API_CATCH_INT
}

int tz7z_can_update(tz7z_archive *archive)
{
  TZ7Z_API_TRY
  return archive && archive->CanUpdate ? 1 : 0;
  TZ7Z_API_CATCH_INT
}

int tz7z_entry_name(tz7z_archive *archive, uint32_t index, char *buffer, int capacity)
{
  TZ7Z_API_TRY
  if (!archive)
    return 0;
  UString name = GetPropStr(archive->Arc, index, kpidPath);
  AString u = ToU8(name);
  int need = (int)u.Len() + 1;
  if (buffer && capacity > 0)
  {
    int copy = capacity - 1;
    if (copy > (int)u.Len()) copy = (int)u.Len();
    if (copy > 0) memcpy(buffer, u.Ptr(), (size_t)copy);
    buffer[copy] = 0;
  }
  return need;
  TZ7Z_API_CATCH_INT
}

int tz7z_entry_info_get(tz7z_archive *archive, uint32_t index, tz7z_entry_info *info)
{
  TZ7Z_API_TRY
  if (!archive || !info)
    return TZ7Z_E_ARG;
  if (!CheckAbi(info->struct_size, info->abi_version, sizeof(*info),
                "tz7z_entry_info", NULL, 0))
    return TZ7Z_E_ARG;
  memset(info, 0, sizeof(*info));
  GetPropU64(archive->Arc, index, kpidSize, info->size);
  GetPropU64(archive->Arc, index, kpidPackSize, info->packed_size);
  UInt64 mt = 0;
  if (GetPropFileTime(archive->Arc, index, kpidMTime, mt))
    info->mtime = mt;
  UInt64 ct = 0;
  if (GetPropFileTime(archive->Arc, index, kpidCTime, ct))
    info->ctime = ct;
  UInt64 at = 0;
  if (GetPropFileTime(archive->Arc, index, kpidATime, at))
    info->atime = at;
  UInt64 v = 0;
  if (GetPropU64(archive->Arc, index, kpidCRC, v))
    info->crc = (uint32_t)v;
  if (GetPropU64(archive->Arc, index, kpidAttrib, v))
    info->attrib = (uint32_t)v;
  info->is_dir = GetPropBool(archive->Arc, index, kpidIsDir, false) ? 1 : 0;
  info->encrypted = GetPropBool(archive->Arc, index, kpidEncrypted, false) ? 1 : 0;
  info->is_anti = GetPropBool(archive->Arc, index, kpidIsAnti, false) ? 1 : 0;
  UInt64 ns = 0;
  if (GetPropU64(archive->Arc, index, kpidNumStreams, ns))
    info->num_streams = (ns > 0x7FFFFFFFULL) ? 0x7FFFFFFF : (int32_t)ns;
  UString method = GetPropStr(archive->Arc, index, kpidMethod);
  AString m = ToU8(method);
  CopyUtf8Truncated(info->method, sizeof(info->method), m.Ptr());
  UString comment = GetPropStr(archive->Arc, index, kpidComment);
  AString c = ToU8(comment);
  CopyUtf8Truncated(info->comment, sizeof(info->comment), c.Ptr());
  return TZ7Z_OK;
  TZ7Z_API_CATCH_INT
}

static bool IsZipFormat(const AString &formatName)
{
  AString f(formatName);
  f.MakeLower_Ascii();
  return f == "zip";
}

int tz7z_set_name_codepage(tz7z_archive *archive, uint32_t codepage)
{
  TZ7Z_API_TRY
  if (!archive)
    return TZ7Z_E_ARG;
  if (codepage == 0)
  {
    archive->NameCodepage = 0;
    return TZ7Z_OK;
  }
  if (!IsZipFormat(archive->FormatName))
    return TZ7Z_E_FORMAT;

  /* The zip handler implements ISetProperties; "cp" switches its name
     decoding to the given code page for entries without the UTF-8 flag.
     Names are decoded lazily by GetProperty, so setting this after Open()
     takes effect. */
  CMyComPtr<ISetProperties> sp;
  if (archive->Arc->QueryInterface(IID_ISetProperties, (void **)&sp) != S_OK || !sp)
    return TZ7Z_E_FORMAT;

  const wchar_t *names[] = { L"cp" };
  PROPVARIANT value;
  InitProp(value);
  value.vt = VT_UI4;
  value.ulVal = (UInt32)codepage;
  if (sp->SetProperties(names, &value, 1) != S_OK)
    return TZ7Z_E_FORMAT;

  archive->NameCodepage = codepage;
  return TZ7Z_OK;
  TZ7Z_API_CATCH_INT
}

static bool CopyBytes(FILE *in, FILE *out, long long count)
{
  std::vector<char> buf(65536);
  while (count > 0)
  {
    size_t want = (size_t)((count < (long long)buf.size()) ? count : (long long)buf.size());
    size_t got = fread(&buf[0], 1, want, in);
    if (got == 0)
      return false;
    if (fwrite(&buf[0], 1, got, out) != got)
      return false;
    count -= (long long)got;
  }
  return true;
}

// Locate the ZIP end-of-central-directory record, and only accept it when its
// comment length lands exactly on the end of the file.
//
// Scanning the tail for the LAST "PK" is not enough: the comment itself
// follows the record, so a signature inside the comment is found first and the
// writer then truncated the file at that offset.  Payload data can contain the
// same bytes as well.
static bool FindZipEocd(FILE *f, long long total, long long &recPos, unsigned &commLen)
{
  recPos = -1;
  commLen = 0;
  if (total < 22)
    return false;
  long long window = 22 + 65535;
  if (window > total)
    window = total;
  long long start = total - window;
  std::vector<unsigned char> buf((size_t)window);
  if (fseeko(f, (off_t)start, SEEK_SET) != 0)
    return false;
  if (fread(&buf[0], 1, (size_t)window, f) != (size_t)window)
    return false;
  for (long long i = window - 22; i >= 0; i--)
  {
    size_t k = (size_t)i;
    if (buf[k] == 0x50 && buf[k + 1] == 0x4B &&
        buf[k + 2] == 0x05 && buf[k + 3] == 0x06)
    {
      unsigned len = (unsigned)buf[k + 20] | ((unsigned)buf[k + 21] << 8);
      if (i + 22 + (long long)len == window)
      {
        recPos = start + i;
        commLen = len;
        return true;
      }
    }
  }
  return false;
}

// The archive comment, read from the ZIP end-of-central-directory record
// rather than through 7-Zip.
//
// 7-Zip decodes a ZIP comment with CP_ACP, which on Unix is the OEM code page:
// a UTF-8 comment comes back as "????" and the original bytes are gone. The
// comment has no encoding flag of its own, so the honest thing is to hand the
// bytes through unchanged and let the UI treat them as UTF-8, which is what
// every tool that writes one on this platform uses.
static bool ReadZipComment(const char *path, AString &out)
{
  out.Empty();
  FILE *f = fopen(path, "rb");
  if (!f)
    return false;
  bool ok = false;
  if (fseeko(f, 0, SEEK_END) == 0)
  {
    long long total = (long long)ftello(f);
    long long recPos = -1;
    unsigned commLen = 0;
    if (FindZipEocd(f, total, recPos, commLen) &&
        fseeko(f, (off_t)(recPos + 22), SEEK_SET) == 0)
    {
      std::vector<char> buf(commLen);
      if (commLen == 0 || fread(&buf[0], 1, commLen, f) == commLen)
      {
        if (commLen)
          out.AddFrom(&buf[0], commLen);
        ok = true;
      }
    }
  }
  fclose(f);
  return ok;
}

// Rewrite a ZIP's end-of-central-directory record with a new comment.
//
// Done on the file rather than through the engine: ZipHandlerOut has no comment
// property at all (it rejects the whole option set when given one), and the
// comment lives in a fixed-size tail field anyway.  The patched copy is written
// to a unique sibling and renamed into place, so a failure leaves the original
// archive untouched.  Returns false (with `err` set) when the file is not a
// readable zip or the comment is too long for the format.
static bool WriteZipComment(const AString &path, const AString &comment,
                            AString &err)
{
  if (comment.Len() > 65535)
  {
    err = "the comment is too long for the ZIP format";
    return false;
  }
  FILE *in = fopen(path.Ptr(), "rb");
  if (!in)
  {
    err = "cannot open the archive to write its comment";
    return false;
  }
  bool ok = false;
  AString tempPath;
  struct stat srcStat;
  bool haveStat = (fstat(fileno(in), &srcStat) == 0);
  if (fseeko(in, 0, SEEK_END) == 0)
  {
    long long total = (long long)ftello(in);
    long long recPos = -1;
    unsigned oldLen = 0;
    if (FindZipEocd(in, total, recPos, oldLen))
    {
      int fd = -1;
      if (CreateUniqueFile(ParentDir(path), BaseName(path), tempPath, fd))
      {
        FILE *out = fdopen(fd, "wb+");
        if (out)
        {
          ok = fseeko(in, 0, SEEK_SET) == 0 &&
               CopyBytes(in, out, recPos);
          if (ok)
          {
            unsigned char header[22];
            ok = fseeko(in, (off_t)recPos, SEEK_SET) == 0 &&
                 fread(header, 1, sizeof(header), in) == sizeof(header);
            if (ok)
            {
              header[20] = (unsigned char)(comment.Len() & 0xFF);
              header[21] = (unsigned char)((comment.Len() >> 8) & 0xFF);
              ok = fwrite(header, 1, sizeof(header), out) == sizeof(header) &&
                   (comment.IsEmpty() ||
                    fwrite(comment.Ptr(), 1, comment.Len(), out) == comment.Len());
            }
          }
          if (ok)
          {
            ok = (fflush(out) == 0);
            if (ok)
            {
              int ofd = fileno(out);
              if (ofd >= 0 && fsync(ofd) != 0 && errno != EINVAL && errno != ENOTSUP)
                ok = false;
            }
          }
          if (fclose(out) != 0)
            ok = false;
          if (!ok)
          {
            err = "cannot write the archive comment";
            unlink(tempPath.Ptr());
          }
        }
        else
        {
          close(fd);
          unlink(tempPath.Ptr());
          err = "cannot write the archive comment";
        }
      }
      else
      {
        err = "cannot create a temporary file for the comment";
      }
    }
    else
    {
      err = "not a readable ZIP archive (no end-of-central-directory record at EOF)";
    }
  }
  fclose(in);
  if (!ok)
    return false;
  if (haveStat && chmod(tempPath.Ptr(), srcStat.st_mode & 07777) != 0)
  {
    /* Losing the mode is not fatal for the comment itself. */
  }
  if (rename(tempPath.Ptr(), path.Ptr()) != 0)
  {
    err = "cannot replace the archive with the commented copy";
    unlink(tempPath.Ptr());
    return false;
  }
  return true;
}

int tz7z_comment(tz7z_archive *archive, char *buffer, int capacity)
{
  TZ7Z_API_TRY
  /* Only ZIP stores a comment this ABI can read; scanning another format's tail
     for a ZIP record would at best return an empty string and at worst invent a
     "comment" out of unrelated bytes. */
  if (!archive || archive->Path.IsEmpty() || !IsZipFormat(archive->FormatName))
    return 1;
  AString comment;
  ReadZipComment(archive->Path.Ptr(), comment);
  int need = (int)comment.Len() + 1;
  if (buffer && capacity > 0)
  {
    int copy = capacity - 1;
    if (copy > (int)comment.Len()) copy = (int)comment.Len();
    if (copy > 0) memcpy(buffer, comment.Ptr(), (size_t)copy);
    buffer[copy] = 0;
  }
  return need;
  TZ7Z_API_CATCH_INT
}

int tz7z_set_comment(tz7z_archive *archive, const char *comment)
{
  TZ7Z_API_TRY
  if (!archive || archive->Path.IsEmpty())
    return TZ7Z_E_ARG;
  if (!IsZipFormat(archive->FormatName))
    return TZ7Z_E_FORMAT;
  AString err;
  AString c;
  if (comment)
    c = comment;
  return WriteZipComment(archive->Path, c, err) ? TZ7Z_OK : TZ7Z_E_FORMAT;
  TZ7Z_API_CATCH_INT
}

static int ExtractInternal(tz7z_archive *archive, const uint32_t *indices,
                           uint32_t count, const char *outDir,
                           const char *singleFile, bool singleMode, bool testMode,
                           const char *password, tz7z_progress_fn progress,
                           void *user, char *err, int errCap,
                           UInt64 prefixLimit,
                           const tz7z_progress_sink *sink)
{
  if (!archive)
    return TZ7Z_E_ARG;
  /* An empty password means "I have none to offer", not "use the empty
     password": Free Pascal always passes a non-NULL (possibly empty) string, so
     the old mix of pw from the argument and pwDefined from the handle made an
     archive opened with a password fail once the caller passed "".  Both come
     from the same source now. */
  UString pw;
  bool pwDefined;
  if (password && *password)
  {
    pw = U8(password);
    pwDefined = true;
  }
  else
  {
    pw = archive->Password;
    pwDefined = archive->PasswordDefined;
  }

  std::vector<UInt32> idx;
  if (indices && count)
  {
    idx.assign(indices, indices + count);
    std::sort(idx.begin(), idx.end());
  }
  const UInt32 *p = idx.empty() ? NULL : &idx[0];
  UInt32 n = idx.empty() ? (UInt32)(Int32)-1 : (UInt32)idx.size();

  CProgressTarget progressTarget(progress, user, sink,
      testMode ? TZ7Z_PH_TEST : TZ7Z_PH_EXTRACT);
  CExtractCallback *cb = new CExtractCallback(archive->Arc,
      outDir ? AString(outDir) : AString(),
      singleFile ? AString(singleFile) : AString(),
      singleMode, testMode, pw, pwDefined, &progressTarget, prefixLimit);
  CMyComPtr<IArchiveExtractCallback> cbRef = cb;

  { /* Cache the entry names up front, but only for a single-stream archive:
       gzip/bzip2 answer kpidPath on the archive and not from inside the extract
       callback, so without this the output file is named "[Content]" instead of
       what the stream says.  Multi-entry archives answer kpidPath in the
       callback, and caching every name of a large archive wasted hundreds of
       MB on an extraction that needed none of them. */
    UInt32 total = 0;
    if (archive->Arc->GetNumberOfItems(&total) == S_OK && total <= 1)
      cb->CacheNames(total);
  }

  HRESULT hr = archive->Arc->Extract(p, n, testMode ? 1 : 0, cbRef);
  /* Limited extraction: the prefix is on disk and the decode was aborted on
     purpose.  Close the file, check the flush, and report success. */
  if (cb->PrefixReached())
  {
    if (!cb->FinishPrefix())
    {
      SetError(err, errCap, cb->Error().Ptr());
      return cb->Result() == TZ7Z_E_IO ? TZ7Z_E_IO : TZ7Z_E_EXTRACT;
    }
    return TZ7Z_OK;
  }
  if (cb->Cancelled())
  {
    SetError(err, errCap, "cancelled");
    return TZ7Z_E_CANCEL;
  }
  if (cb->PasswordRequested() && !pwDefined)
  {
    SetError(err, errCap, "password required");
    return TZ7Z_E_PASSWORD;
  }
  if (hr != S_OK || cb->Result() != TZ7Z_OK)
  {
    AString msg = cb->Error();
    if (msg.IsEmpty())
    {
      char tmp[64];
      snprintf(tmp, sizeof(tmp), "7-Zip error 0x%08x", (unsigned)hr);
      msg = tmp;
    }
    SetError(err, errCap, msg.Ptr());
    int r = cb->Result();
    return r == TZ7Z_OK ? TZ7Z_E_EXTRACT : r;
  }
  /* The password was right (the handler got it) but a link target was missing
     or unreadable: report that instead of pretending the whole extraction was
     fine.  A CRC/data error keeps its TZ7Z_E_EXTRACT code -- rewriting every
     failure on an encrypted archive to "wrong password" made the UI ask for the
     password forever. */
  if (!testMode && !cb->CreatePendingHardLinks())
  {
    SetError(err, errCap, cb->Error().Ptr());
    return TZ7Z_E_IO;
  }
  return TZ7Z_OK;
}

int tz7z_extract(tz7z_archive *archive, const uint32_t *indices, uint32_t count,
                 const char *out_dir, const char *password,
                 tz7z_progress_fn progress, void *user,
                 char *err, int err_capacity)
{
  TZ7Z_API_TRY
  if (!out_dir || !*out_dir)
  {
    SetError(err, err_capacity, "output directory is empty");
    return TZ7Z_E_ARG;
  }
  AString dir(out_dir);
  if (!PathExists(dir))
  {
    if (!MakeDirs(dir))
    {
      SetError(err, err_capacity, "cannot create output directory");
      return TZ7Z_E_IO;
    }
  }
  return ExtractInternal(archive, indices, count, out_dir, NULL, false, false,
                         password, progress, user, err, err_capacity, 0, NULL);
  TZ7Z_API_CATCH_INT
}

int tz7z_extract_ex(tz7z_archive *archive,
                    const uint32_t *indices, uint32_t count,
                    const char *out_dir, const char *password,
                    tz7z_progress_fn progress, void *user,
                    const tz7z_progress_sink *sink,
                    char *err, int err_capacity)
{
  TZ7Z_API_TRY
  if (!CheckProgressSink(sink, err, err_capacity))
    return TZ7Z_E_ARG;
  if (!out_dir || !*out_dir)
  {
    SetError(err, err_capacity, "output directory is empty");
    return TZ7Z_E_ARG;
  }
  AString dir(out_dir);
  if (!PathExists(dir))
  {
    if (!MakeDirs(dir))
    {
      SetError(err, err_capacity, "cannot create output directory");
      return TZ7Z_E_IO;
    }
  }
  return ExtractInternal(archive, indices, count, out_dir, NULL, false, false,
                         password, progress, user, err, err_capacity, 0, sink);
  TZ7Z_API_CATCH_INT
}

int tz7z_test(tz7z_archive *archive, const uint32_t *indices, uint32_t count,
              const char *password, tz7z_progress_fn progress, void *user,
              char *err, int err_capacity)
{
  TZ7Z_API_TRY
  return ExtractInternal(archive, indices, count, "", NULL, false, true,
                         password, progress, user, err, err_capacity, 0, NULL);
  TZ7Z_API_CATCH_INT
}

int tz7z_test_ex(tz7z_archive *archive, const uint32_t *indices, uint32_t count,
                 const char *password, tz7z_progress_fn progress, void *user,
                 const tz7z_progress_sink *sink,
                 char *err, int err_capacity)
{
  TZ7Z_API_TRY
  if (!CheckProgressSink(sink, err, err_capacity))
    return TZ7Z_E_ARG;
  return ExtractInternal(archive, indices, count, "", NULL, false, true,
                         password, progress, user, err, err_capacity, 0, sink);
  TZ7Z_API_CATCH_INT
}

int tz7z_extract_one(tz7z_archive *archive, uint32_t index, const char *out_file,
                     const char *password, tz7z_progress_fn progress, void *user,
                     char *err, int err_capacity)
{
  TZ7Z_API_TRY
  if (!out_file || !*out_file)
  {
    SetError(err, err_capacity, "output file is empty");
    return TZ7Z_E_ARG;
  }
  AString parent = ParentDir(AString(out_file));
  if (!MakeDirs(parent))
  {
    SetError(err, err_capacity, "cannot create output directory");
    return TZ7Z_E_IO;
  }
  return ExtractInternal(archive, &index, 1, "", out_file, true, false,
                         password, progress, user, err, err_capacity, 0, NULL);
  TZ7Z_API_CATCH_INT
}

/* Extract at most max_bytes of one entry into out_file and report success when
   the prefix (or the whole entry, if it is shorter) has been written.  A
   max_bytes of 0 means "no limit" and is equivalent to tz7z_extract_one.  The
   file on disk is the prefix; the decoder is stopped as soon as the byte limit
   is reached, so a 100 MB entry costs no full temporary file. */
int tz7z_extract_one_prefix(tz7z_archive *archive, uint32_t index,
                            const char *out_file, const char *password,
                            uint64_t max_bytes, char *err, int err_capacity)
{
  TZ7Z_API_TRY
  if (!archive)
  {
    SetError(err, err_capacity, "invalid archive handle");
    return TZ7Z_E_ARG;
  }
  if (!out_file || !*out_file)
  {
    SetError(err, err_capacity, "output file is empty");
    return TZ7Z_E_ARG;
  }
  UInt32 total = 0;
  if (archive->Arc->GetNumberOfItems(&total) == S_OK && index >= total)
  {
    SetError(err, err_capacity, "entry index is out of range");
    return TZ7Z_E_ARG;
  }
  AString parent = ParentDir(AString(out_file));
  if (!MakeDirs(parent))
  {
    SetError(err, err_capacity, "cannot create output directory");
    return TZ7Z_E_IO;
  }
  return ExtractInternal(archive, &index, 1, "", out_file, true, false,
                         password, NULL, NULL, err, err_capacity, max_bytes, NULL);
  TZ7Z_API_CATCH_INT
}

// ---------------------------------------------------------------------------
// create / modify
// ---------------------------------------------------------------------------

static bool FillItemFromDisk(CCreateItem &it, const AString &diskPath,
                             const UString &arcPath, bool isDir)
{
  struct stat st;
  if (stat(diskPath.Ptr(), &st) != 0)
    return false;
  it.DiskPath = diskPath;
  it.ArcPath = arcPath;
  it.IsDir = isDir || S_ISDIR(st.st_mode);
  it.Size = S_ISREG(st.st_mode) ? (UInt64)st.st_size : 0;
  it.Attrib = AttribFromStat(st);
  it.CTime = UnixToFileTime((UInt64)st.st_ctime);
  it.ATime = UnixToFileTime((UInt64)st.st_atime);
  it.MTime = UnixToFileTime((UInt64)st.st_mtime);
  return true;
}

static HRESULT SetCommonProperties(IOutArchive *out, const tz7z_create_options &opt,
                                   const AString &formatName)
{
  CMyComPtr<ISetProperties> sp;
  HRESULT qhr = out->QueryInterface(IID_ISetProperties, (void **)&sp);
  if (qhr != S_OK || !sp)
    return S_OK;

  UStringVector names;
  UStringVector extraNames;   /* keys that came from the raw "extra" field */
  std::vector<PROPVARIANT> values;
  AString fmt = formatName;
  fmt.MakeLower_Ascii();

  bool is7z = (fmt == "7z");
  bool isZip = (fmt == "zip");

  if (opt.level >= 0 && opt.level <= 9)
  {
    names.Add(UString(L"x"));
    PROPVARIANT p; InitProp(p); p.vt = VT_UI4; p.ulVal = (UInt32)opt.level;
    values.push_back(p);
  }
  if (opt.method && *opt.method)
  {
    names.Add(UString(L"m"));
    PROPVARIANT p; InitProp(p); p.vt = VT_BSTR;
    UString m = U8(opt.method);
    p.bstrVal = SysAllocString(m);
    values.push_back(p);
  }
  if (opt.threads > 0)
  {
    names.Add(UString(L"mt"));
    PROPVARIANT p; InitProp(p); p.vt = VT_UI4; p.ulVal = (UInt32)opt.threads;
    values.push_back(p);
  }
  if (opt.solid >= 0 && is7z)
  {
    names.Add(UString(L"s"));
    PROPVARIANT p; InitProp(p); p.vt = VT_BOOL;
    p.boolVal = opt.solid ? VARIANT_TRUE : VARIANT_FALSE;
    values.push_back(p);
  }
  if (opt.encrypt_names && is7z)
  {
    names.Add(UString(L"he"));
    PROPVARIANT p; InitProp(p); p.vt = VT_BOOL; p.boolVal = VARIANT_TRUE;
    values.push_back(p);
  }
  if (opt.zip_aes256 && isZip && opt.password && *opt.password)
  {
    names.Add(UString(L"em"));
    PROPVARIANT p; InitProp(p); p.vt = VT_BSTR;
    p.bstrVal = SysAllocString(UString(L"AES256"));
    values.push_back(p);
  }

  /* Advanced fields.  Each is forwarded only when set, so an unset field keeps
     the engine's default instead of forcing a value. */
  {
    /* A dictionary belongs to LZMA/LZMA2/PPMd; handing it to Copy or Deflate
       makes the handler reject the WHOLE job with E_INVALIDARG. */
    AString mname(opt.method ? opt.method : "");
    mname.MakeLower_Ascii();
    bool hasDict = (mname == "lzma" || mname == "lzma2" || mname == "ppmd");
  if (opt.dictionary_size > 0 && hasDict)
  {
    names.Add(UString(L"d"));
    /* As a string with a unit suffix, which is the form the handler parses into
       a log size. A VT_UI4 byte count is also accepted by the source, but only
       when it lands on an exact power of two; going through the string path
       matches what the 7-Zip command line sends and removes that constraint. */
    PROPVARIANT p; InitProp(p); p.vt = VT_BSTR;
    char dsz[64];
    if ((opt.dictionary_size & (opt.dictionary_size - 1)) == 0 &&
        opt.dictionary_size >= (1ull << 20))
      snprintf(dsz, sizeof(dsz), "%llum", (unsigned long long)(opt.dictionary_size >> 20));
    else
      snprintf(dsz, sizeof(dsz), "%llu", (unsigned long long)opt.dictionary_size);
    p.bstrVal = SysAllocString(U8(dsz));
    values.push_back(p);
  }
  }
  if (opt.word_size > 0)
  {
    /* "o" is the PPMd word size.  Sending it to any other encoder (a preset
       keeps the field when the method is switched to LZMA2) makes the handler
       reject the WHOLE job with E_INVALIDARG. */
    AString m(opt.method ? opt.method : "");
    m.MakeLower_Ascii();
    if (m == "ppmd")
    {
      names.Add(UString(L"o"));
      PROPVARIANT p; InitProp(p); p.vt = VT_UI4; p.ulVal = (UInt32)opt.word_size;
      values.push_back(p);
    }
  }
  if (opt.match_finder && *opt.match_finder)
  {
    names.Add(UString(L"mf"));
    PROPVARIANT p; InitProp(p); p.vt = VT_BSTR;
    p.bstrVal = SysAllocString(U8(opt.match_finder));
    values.push_back(p);
  }
  if (opt.num_passes > 0 && opt.method && *opt.method)
  {
    /* Only BZip2 and Deflate have a pass count; LZMA/LZMA2 reject the property
       and 7-Zip then fails the WHOLE create with E_INVALIDARG, so it is
       forwarded only to the encoders that understand it. */
    AString m(opt.method);
    m.MakeLower_Ascii();
    if (m == "bzip2" || m == "deflate")
    {
      names.Add(UString(L"pass"));
      PROPVARIANT p; InitProp(p); p.vt = VT_UI4; p.ulVal = (UInt32)opt.num_passes;
      values.push_back(p);
    }
  }
  if (isZip && opt.codepage > 0)
  {
    names.Add(UString(L"cp"));
    PROPVARIANT p; InitProp(p); p.vt = VT_UI4; p.ulVal = (UInt32)opt.codepage;
    values.push_back(p);
    /* cp alone is not enough on Unix: ZipHandlerOut only takes the code-page
       branch when ForceLocal is set too, otherwise every name is still written
       as UTF-8 with the flag set. "cl=1" is what the 7-Zip command line's
       "-mcl=on" maps to. */
    if (!opt.force_utf8)
    {
      names.Add(UString(L"cl"));
      PROPVARIANT q; InitProp(q); q.vt = VT_BOOL; q.boolVal = VARIANT_TRUE;
      values.push_back(q);
    }
  }
  if (isZip && opt.force_utf8)
  {
    names.Add(UString(L"cu"));
    PROPVARIANT p; InitProp(p); p.vt = VT_BOOL; p.boolVal = VARIANT_TRUE;
    values.push_back(p);
  }
  if (opt.extra_options && *opt.extra_options)
  {
    /* "name=value:name=value".  A bare name means a boolean true, matching the
       7-Zip command line's "-mx=9 -mmt=8" abbreviations. */
    AString listed(opt.extra_options);
    int start = 0;
    for (int i = 0; i <= listed.Len(); i++)
    {
      if (i < listed.Len() && listed[i] != ':')
        continue;
      AString item = listed.Mid((unsigned)start, (unsigned)(i - start));
      start = i + 1;
      item.Trim();
      if (item.IsEmpty())
        continue;
      int eq = item.Find('=');
      AString key = (eq >= 0) ? item.Left((unsigned)eq) : item;
      AString val = (eq >= 0) ? item.Mid((unsigned)eq + 1, (unsigned)item.Len() - (unsigned)eq - 1) : AString("");
      key.Trim();
      if (key.IsEmpty())
        continue;
      /* "mt" already has a dedicated field, and letting the raw pair through
         a second time makes the handler see two values for one property and
         reject the job. Same for a key the handler does not know: the escape
         hatch is a convenience, not a way to break a working create. */
      {
        AString lk(key);
        lk.MakeLower_Ascii();
        if (lk == "mt" || lk == "x" || lk == "d" || lk == "m" || lk == "pass" || lk == "mf")
          continue;
      }
      names.Add(UString(key));
      extraNames.Add(UString(key));
      PROPVARIANT p; InitProp(p);
      bool numeric = !val.IsEmpty();
      for (unsigned k = 0; k < val.Len() && numeric; k++)
        if (val[k] < '0' || val[k] > '9')
          numeric = false;
      if (val.IsEmpty())
      {
        p.vt = VT_BOOL; p.boolVal = VARIANT_TRUE;
      }
      else if (numeric)
      {
        p.vt = VT_UI8; p.uhVal.QuadPart = (ULONGLONG)strtoull(val.Ptr(), NULL, 10);
      }
      else if (val.IsEqualTo("on") || val.IsEqualTo("off"))
      {
        p.vt = VT_BOOL;
        p.boolVal = val.IsEqualTo("on") ? VARIANT_TRUE : VARIANT_FALSE;
      }
      else
      {
        p.vt = VT_BSTR;
        p.bstrVal = SysAllocString(U8(val));
      }
      values.push_back(p);
    }
  }

  HRESULT hr = S_OK;
  if (!names.IsEmpty())
  {
    std::vector<const wchar_t *> ptrs;
    for (unsigned i = 0; i < names.Size(); i++)
      ptrs.push_back((const wchar_t *)names[i]);
    hr = sp->SetProperties(&ptrs[0], &values[0], (UInt32)ptrs.size());
    if (hr != S_OK)
    {
      /* The raw "extra options" field is an escape hatch typed by hand. A typo
         there must not sink an otherwise valid create, so the whole request is
         retried without it -- the dedicated fields still apply, and the user
         gets a usable archive instead of an error. */
      if (!extraNames.IsEmpty())
      {
        /* Deep-copy the kept properties before releasing the originals.  The old
           retry copied the PROPVARIANT structs shallowly, cleared (freed) every
           BSTR they pointed at, and then handed the dangling pointers to
           SetProperties -- a use-after-free followed by a double free. */
        UStringVector n2;
        std::vector<PROPVARIANT> v2;
        bool copied = true;
        for (unsigned k = 0; k < names.Size(); k++)
        {
          bool skip = false;
          for (unsigned x = 0; x < extraNames.Size(); x++)
            if (names[k] == extraNames[x]) skip = true;
          if (skip) continue;
          PROPVARIANT cp;
          InitProp(cp);
          if (VariantCopy(&cp, &values[k]) != S_OK)
          {
            ClearProp(cp);
            copied = false;
            break;
          }
          n2.Add(names[k]);
          v2.push_back(cp);
        }
        for (size_t k = 0; k < values.size(); k++)
          VariantClear(&values[k]);
        if (!copied)
        {
          for (size_t k = 0; k < v2.size(); k++)
            VariantClear(&v2[k]);
          return E_OUTOFMEMORY;
        }
        values.swap(v2);
        names = n2;
        if (!names.IsEmpty())
        {
          std::vector<const wchar_t *> p2;
          for (unsigned k = 0; k < names.Size(); k++)
            p2.push_back((const wchar_t *)names[k]);
          hr = sp->SetProperties(&p2[0], &values[0], (UInt32)p2.size());
        }
        else
          hr = S_OK;
      }
    }
  }
  for (size_t i = 0; i < values.size(); i++)
    VariantClear(&values[i]);
  return hr;
}
static void BuildItemList(const tz7z_input *inputs, uint32_t count,
                          std::vector<CCreateItem> &items,
                          char *err, int errCap, int &errorCode)
{
  for (uint32_t i = 0; i < count; i++)
  {
    if (!CheckAbi(inputs[i].struct_size, inputs[i].abi_version, sizeof(tz7z_input),
                  "tz7z_input", err, errCap))
    {
      errorCode = TZ7Z_E_ARG;
      return;
    }
    /* A NULL path used to be skipped silently: the caller asked for N inputs
       and got a "successful" archive that contained N-1 of them. */
    if (!inputs[i].disk_path || !inputs[i].arc_path)
    {
      char msg[256];
      snprintf(msg, sizeof(msg), "input %u has no %s path",
               (unsigned)(i + 1),
               !inputs[i].disk_path ? "disk" : "archive");
      SetError(err, errCap, msg);
      errorCode = TZ7Z_E_ARG;
      return;
    }
    CCreateItem it;
    AString disk(inputs[i].disk_path);
    UString arc = U8(inputs[i].arc_path);
    if (!FillItemFromDisk(it, disk, arc, inputs[i].is_dir != 0))
    {
      errorCode = TZ7Z_E_IO;
      {
        // Name the file: "cannot stat input file" alone leaves the user unable
        // to tell which of a hundred inputs was the problem.
        char msg[1024];
        snprintf(msg, sizeof(msg), "cannot stat input file: %s", disk.Ptr());
        SetError(err, errCap, msg);
      }
      return;
    }
    items.push_back(it);
  }
}

static void DeleteVolumeFiles(const AString &base, unsigned count)
{
  for (unsigned i = 1; i <= count; i++)
    unlink(VolumePath(base, i).Ptr());
}

// One output target: a single archive file, or a split-volume set.
//
// Both kinds write to unique temporary names first and only touch the final
// names once every byte is on disk and the stream has been closed and synced.
// Any failure therefore leaves the previous archive (or volume set) exactly as
// it was; the "unlink the target first" of the old code made every failure path
// destroy the user's archive.
class COutputFile
{
public:
  AString FinalPath;    // the single file, or the volume base ("x.7z")
  bool Volumes;
  AString TempPath;     // unique temporary file, or unique temporary volume base
  CMyComPtr<IOutStream> Stream;
  CFileOutStream *File;
  CMultiOutStream *Vol;
  unsigned VolumeCount;
  bool Begun;
  bool Committed;

  COutputFile()
    : Volumes(false), File(0), Vol(0), VolumeCount(0),
      Begun(false), Committed(false) {}

  ~COutputFile() { Abort(); }

  bool Begin(const AString &finalPath, bool volumes, UInt64 volumeSize,
             AString &err)
  {
    FinalPath = finalPath;
    Volumes = volumes;
    AString dir = ParentDir(finalPath);
    if (!PathExists(dir))
      MakeDirs(dir);
    int fd = -1;
    if (!CreateUniqueFile(dir, BaseName(finalPath), TempPath, fd))
    {
      err = "cannot create a temporary archive";
      return false;
    }
    if (volumes)
    {
      /* Reserve a unique base name, then let CMultiOutStream create the part
         files next to it.  The placeholder itself is not used. */
      close(fd);
      unlink(TempPath.Ptr());
      Vol = new CMultiOutStream();
      Vol->Prefix = TempPath;
      Vol->Prefix.Add_Dot();
      CRecordVector<UInt64> sizes;
      sizes.Add(volumeSize);
      Vol->Init(sizes);
      Stream = Vol;
    }
    else
    {
      FILE *f = fdopen(fd, "wb+");
      if (!f)
      {
        close(fd);
        unlink(TempPath.Ptr());
        err = "cannot create a temporary archive";
        return false;
      }
      File = new CFileOutStream();
      if (!File->Adopt(f))
      {
        delete File;
        File = 0;
        fclose(f);
        unlink(TempPath.Ptr());
        err = "cannot create a temporary archive";
        return false;
      }
      Stream = File;
    }
    Begun = true;
    return true;
  }

  bool CloseAndCheck(AString &err)
  {
    if (Volumes)
    {
      if (!Vol)
        return false;
      unsigned n = 0;
      HRESULT vhr = Vol->FinalFlush_and_CloseFiles(n);
      VolumeCount = n;
      if (vhr != S_OK)
      {
        err = "cannot finish writing the split archive";
        return false;
      }
      return true;
    }
    if (!File || !File->Close())
    {
      err = "cannot write the archive";
      return false;
    }
    return true;
  }

  // zipComment is applied to the temporary output (the last part for volumes)
  // before anything is renamed into place; a failure here aborts the whole
  // operation with the original archive untouched.
  bool Commit(const AString *zipComment, AString &err)
  {
    if (!Begun || Committed)
      return false;
    if (!CloseAndCheck(err))
    {
      Abort();
      return false;
    }
    if (zipComment)
    {
      AString commentPath = Volumes ? VolumePath(TempPath, VolumeCount) : TempPath;
      if (!WriteZipComment(commentPath, *zipComment, err))
      {
        Abort();
        return false;
      }
    }
    if (Volumes)
    {
      if (VolumeCount == 0)
      {
        err = "no split volumes were written";
        Abort();
        return false;
      }
      // The parts have been flushed and closed; keep the temporary files while
      // they are renamed into their final names.
      Vol->NeedDelete = false;
      Stream.Release();
      Vol = 0;
      bool ok = true;
      for (unsigned i = 1; i <= VolumeCount; i++)
      {
        AString from(VolumePath(TempPath, i));
        AString to(VolumePath(FinalPath, i));
        if (rename(from.Ptr(), to.Ptr()) != 0)
        {
          ok = false;
          break;
        }
      }
      if (!ok)
      {
        err = "cannot replace the split archive";
        DeleteVolumeFiles(TempPath, VolumeCount);
        Begun = false;
        return false;
      }
      // A plain archive with the same base would shadow the volume set.
      unlink(FinalPath.Ptr());
      for (unsigned i = VolumeCount + 1; i <= 999; i++)
        unlink(VolumePath(FinalPath, i).Ptr());
      Committed = true;
      Begun = false;
      return true;
    }

    // Keep the permissions of the archive being replaced; for a new archive use
    // what fopen("wb+") would have produced (the mkstemp temporary is 0600).
    struct stat st;
    mode_t mode = DefaultFileMode();
    if (stat(FinalPath.Ptr(), &st) == 0)
      mode = (mode_t)(st.st_mode & 07777);
    if (chmod(TempPath.Ptr(), mode) != 0)
    {
      /* Best effort: failing to copy the mode must not lose the archive. */
    }
    Stream.Release();
    File = 0;
    if (rename(TempPath.Ptr(), FinalPath.Ptr()) != 0)
    {
      err = "cannot replace the archive";
      unlink(TempPath.Ptr());
      Begun = false;
      return false;
    }
    Committed = true;
    Begun = false;
    return true;
  }

  void Abort()
  {
    if (Stream)
    {
      if (File && File->IsOpen())
        File->Close();
      if (Vol)
        Vol->NeedDelete = true;
      Stream.Release();
      File = 0;
      Vol = 0;
    }
    if (!Committed && !Volumes && !TempPath.IsEmpty())
      unlink(TempPath.Ptr());
    Begun = false;
  }
};

static int CreateArchiveInternal(const char *archive_path,
                                 const tz7z_create_options *options,
                                 const tz7z_input *inputs, uint32_t count,
                                 tz7z_progress_fn progress, void *user,
                                 char *err, int err_capacity,
                                 const tz7z_progress_sink *sink)
{
  TZ7Z_API_TRY
  if (!archive_path || !*archive_path || !options || !options->format)
  {
    SetError(err, err_capacity, "invalid create arguments");
    return TZ7Z_E_ARG;
  }
  if (!CheckAbi(options->struct_size, options->abi_version, sizeof(*options),
                "tz7z_create_options", err, err_capacity))
    return TZ7Z_E_ARG;
  if (!LoadFormats())
  {
    SetError(err, err_capacity, "cannot load 7-Zip engine");
    return TZ7Z_E_OPEN;
  }

  if (count > 0 && !inputs)
  {
    SetError(err, err_capacity, "the input list is NULL");
    return TZ7Z_E_ARG;
  }

  AString formatName(options->format);
  int fi = FindFormatByName(formatName, true);
  if (fi < 0)
  {
    SetError(err, err_capacity, "unsupported or read-only archive format");
    return TZ7Z_E_FORMAT;
  }

  std::vector<CCreateItem> items;
  int itemError = TZ7Z_OK;
  BuildItemList(inputs, count, items, err, err_capacity, itemError);
  if (itemError != TZ7Z_OK)
    return itemError;
  if (items.empty())
  {
    SetError(err, err_capacity, "nothing to compress");
    return TZ7Z_E_ARG;
  }

  AString outPath(archive_path);
  bool volumes = options->volume_size > 0;
  COutputFile output;
  AString outErr;
  if (!output.Begin(outPath, volumes, options->volume_size, outErr))
  {
    SetError(err, err_capacity, outErr.Ptr());
    return TZ7Z_E_IO;
  }

  IOutArchive *rawOut = 0;
  HRESULT hr = CreateObject(&g_Formats[fi].clsid, &IID_IOutArchive, (void **)&rawOut);
  if (hr != S_OK || !rawOut)
  {
    SetError(err, err_capacity, "cannot create archive handler");
    return TZ7Z_E_FORMAT;
  }
  CMyComPtr<IOutArchive> outArc;
  outArc.Attach(rawOut);

  if (SetCommonProperties(outArc, *options, ToU8(g_Formats[fi].name)) != S_OK)
  {
    SetError(err, err_capacity, "archive handler rejected compression options");
    return TZ7Z_E_FORMAT;
  }

  UString pw = U8(options->password);
  bool pwDefined = options->password && *options->password;
  CProgressTarget progressTarget(progress, user, sink, TZ7Z_PH_CREATE);
  CUpdateCallback *cb = new CUpdateCallback(&items, pw, pwDefined, &progressTarget);
  CMyComPtr<IArchiveUpdateCallback2> cbRef = cb;

  hr = outArc->UpdateItems(output.Stream, (UInt32)items.size(), cbRef);
  if (cb->Cancelled())
  {
    SetError(err, err_capacity, "cancelled");
    return TZ7Z_E_CANCEL;
  }
  if (hr != S_OK || cb->Result() != TZ7Z_OK)
  {
    char tmp[96];
    snprintf(tmp, sizeof(tmp), "7-Zip could not create the archive (0x%08x)", (unsigned)hr);
    SetError(err, err_capacity, tmp);
    return TZ7Z_E_UPDATE;
  }
  if (!output.Commit(NULL, outErr))
  {
    SetError(err, err_capacity, outErr.Ptr());
    return TZ7Z_E_IO;
  }
  return TZ7Z_OK;
  TZ7Z_API_CATCH_INT
}

int tz7z_create(const char *archive_path, const tz7z_create_options *options,
                const tz7z_input *inputs, uint32_t count,
                tz7z_progress_fn progress, void *user,
                char *err, int err_capacity)
{
  return CreateArchiveInternal(archive_path, options, inputs, count, progress,
                               user, err, err_capacity, NULL);
}

int tz7z_create_ex(const char *archive_path, const tz7z_create_options *options,
                   const tz7z_input *inputs, uint32_t count,
                   tz7z_progress_fn progress, void *user,
                   const tz7z_progress_sink *sink,
                   char *err, int err_capacity)
{
  if (!CheckProgressSink(sink, err, err_capacity))
    return TZ7Z_E_ARG;
  return CreateArchiveInternal(archive_path, options, inputs, count, progress,
                               user, err, err_capacity, sink);
}

static void ReadOldItems(tz7z_archive *a, std::vector<CCreateItem> &old,
                         std::vector<UString> &names)
{
  int n = tz7z_entry_count(a);
  for (int i = 0; i < n; i++)
  {
    CCreateItem it;
    it.NewData = false;
    it.OldIndex = i;
    it.ArcPath = GetPropStr(a->Arc, (UInt32)i, kpidPath);
    it.IsDir = GetPropBool(a->Arc, (UInt32)i, kpidIsDir, false);
    UInt64 sz = 0;
    GetPropU64(a->Arc, (UInt32)i, kpidSize, sz);
    it.Size = sz;
    UInt64 at = 0;
    if (GetPropU64(a->Arc, (UInt32)i, kpidAttrib, at))
      it.Attrib = (UInt32)at;
    UInt64 t = 0;
    if (GetPropFileTime(a->Arc, (UInt32)i, kpidMTime, t))
      it.MTime = UnixToFileTime(t);
    if (GetPropFileTime(a->Arc, (UInt32)i, kpidCTime, t))
      it.CTime = UnixToFileTime(t);
    if (GetPropFileTime(a->Arc, (UInt32)i, kpidATime, t))
      it.ATime = UnixToFileTime(t);
    old.push_back(it);
    names.push_back(it.ArcPath);
  }
}

static int ModifyArchiveInternal(const char *archive_path, const char *password,
                                 const tz7z_create_options *options,
                                 const uint32_t *remove_indices, uint32_t remove_count,
                                 const tz7z_input *add_inputs, uint32_t add_count,
                                 tz7z_progress_fn progress, void *user,
                                 char *err, int err_capacity,
                                 const tz7z_progress_sink *sink)
{
  TZ7Z_API_TRY
  if (!archive_path || !*archive_path)
  {
    SetError(err, err_capacity, "invalid archive path");
    return TZ7Z_E_ARG;
  }
  tz7z_archive *rawArchive = 0;
  int r = tz7z_open_ex(archive_path, password, NULL, &rawArchive, err, err_capacity);
  if (r != TZ7Z_OK)
    return r;
  struct CArchiveDeleter
  {
    void operator()(tz7z_archive *p) const { delete p; }
  };
  std::unique_ptr<tz7z_archive, CArchiveDeleter> archive(rawArchive);
  tz7z_archive *a = archive.get();
  if (!a->CanUpdate)
  {
    SetError(err, err_capacity, "this archive format cannot be modified");
    return TZ7Z_E_UNSUPPORTED;
  }

  if (options &&
      !CheckAbi(options->struct_size, options->abi_version, sizeof(*options),
                "tz7z_create_options", err, err_capacity))
    return TZ7Z_E_ARG;
  tz7z_create_options defaults;
  memset(&defaults, 0, sizeof(defaults));
  defaults.level = -1;
  defaults.solid = -1;
  defaults.format = a->FormatName.Ptr();
  const tz7z_create_options &opt = options ? *options : defaults;

  /* A split archive cannot be written back as one file: the old code did
     exactly that and left the stale .002... parts next to a torn .001.  With a
     volume size the set is rebuilt as a set; without one, refuse. */
  AString realPath(archive_path);
  bool volumes = opt.volume_size > 0;
  AString finalBase = a->IsSplit ? SplitPartBase(realPath) : realPath;
  if (a->IsSplit && !volumes)
  {
    SetError(err, err_capacity,
             "refusing to collapse a split archive into one file: a volume size is required");
    return TZ7Z_E_ARG;
  }

  std::vector<CCreateItem> oldItems;
  std::vector<UString> oldNames;
  ReadOldItems(a, oldItems, oldNames);

  std::vector<bool> remove(oldItems.size(), false);
  for (uint32_t i = 0; i < remove_count; i++)
    if (remove_indices[i] < remove.size())
      remove[remove_indices[i]] = true;

  std::vector<CCreateItem> outItems;
  for (size_t i = 0; i < oldItems.size(); i++)
    if (!remove[i])
      outItems.push_back(oldItems[i]);

  if (add_count > 0 && !add_inputs)
  {
    SetError(err, err_capacity, "the input list is NULL");
    return TZ7Z_E_ARG;
  }
  int itemError = TZ7Z_OK;
  if (add_inputs && add_count)
    BuildItemList(add_inputs, add_count, outItems, err, err_capacity, itemError);
  if (itemError != TZ7Z_OK)
    return itemError;

  COutputFile output;
  AString outErr;
  if (!output.Begin(finalBase, volumes, opt.volume_size, outErr))
  {
    SetError(err, err_capacity, outErr.Ptr());
    return TZ7Z_E_IO;
  }

  CMyComPtr<IOutArchive> outArc;
  HRESULT hr = a->Arc->QueryInterface(IID_IOutArchive, (void **)&outArc);
  if (hr != S_OK || !outArc)
  {
    SetError(err, err_capacity, "archive handler cannot update");
    return TZ7Z_E_UNSUPPORTED;
  }

  if (SetCommonProperties(outArc, opt, a->FormatName) != S_OK)
  {
    SetError(err, err_capacity, "archive handler rejected update options");
    return TZ7Z_E_FORMAT;
  }

  /* Same-source password selection as extraction: an empty argument means "I
     have no new password", so the one the archive was opened with is used. */
  UString pw;
  bool pwDefined;
  if (password && *password)
  {
    pw = U8(password);
    pwDefined = true;
  }
  else
  {
    pw = a->Password;
    pwDefined = a->PasswordDefined;
  }
  CProgressTarget progressTarget(progress, user, sink, TZ7Z_PH_CREATE);
  CUpdateCallback *cb = new CUpdateCallback(&outItems, pw, pwDefined, &progressTarget);
  CMyComPtr<IArchiveUpdateCallback2> cbRef = cb;

  hr = outArc->UpdateItems(output.Stream, (UInt32)outItems.size(), cbRef);
  if (cb->Cancelled())
  {
    SetError(err, err_capacity, "cancelled");
    return TZ7Z_E_CANCEL;
  }
  if (hr != S_OK || cb->Result() != TZ7Z_OK)
  {
    SetError(err, err_capacity, "7-Zip could not update the archive");
    return TZ7Z_E_UPDATE;
  }

  AString comment;
  const AString *commentPtr = NULL;
  if (opt.has_comment && IsZipFormat(a->FormatName))
  {
    if (opt.comment)
      comment = opt.comment;
    commentPtr = &comment;
  }
  if (!output.Commit(commentPtr, outErr))
  {
    SetError(err, err_capacity, outErr.Ptr());
    return TZ7Z_E_IO;
  }
  return TZ7Z_OK;
  TZ7Z_API_CATCH_INT
}

int tz7z_modify(const char *archive_path, const char *password,
                const tz7z_create_options *options,
                const uint32_t *remove_indices, uint32_t remove_count,
                const tz7z_input *add_inputs, uint32_t add_count,
                tz7z_progress_fn progress, void *user,
                char *err, int err_capacity)
{
  return ModifyArchiveInternal(archive_path, password, options,
                               remove_indices, remove_count,
                               add_inputs, add_count, progress, user,
                               err, err_capacity, NULL);
}

int tz7z_modify_ex(const char *archive_path, const char *password,
                   const tz7z_create_options *options,
                   const uint32_t *remove_indices, uint32_t remove_count,
                   const tz7z_input *add_inputs, uint32_t add_count,
                   tz7z_progress_fn progress, void *user,
                   const tz7z_progress_sink *sink,
                   char *err, int err_capacity)
{
  if (!CheckProgressSink(sink, err, err_capacity))
    return TZ7Z_E_ARG;
  return ModifyArchiveInternal(archive_path, password, options,
                               remove_indices, remove_count,
                               add_inputs, add_count, progress, user,
                               err, err_capacity, sink);
}
