/*
 * tz7z.h - minimal C ABI around the 7-Zip archive engine.
 *
 * The engine itself is the real 7-Zip dynamic library (lib7z.dylib on macOS).
 * This shim exists because 7-Zip's public interface is a C++ COM ABI, which is
 * painful to consume from Free Pascal.  Everything crossing this header is
 * plain C, UTF-8, little endian POD.
 *
 * Contract:
 *  - Thread model: the library is safe to use from several threads at once.
 *    The engine format table is loaded once, under a lock.  Distinct
 *    tz7z_archive handles may be used concurrently; one handle must not be
 *    used by two threads at the same time (its callbacks and progress target
 *    are not re-entrant).
 *  - Ownership: a tz7z_archive is created by tz7z_open and must be released
 *    with tz7z_close.  tz7z_format_name returns a pointer owned by the handle,
 *    valid until tz7z_close -- copy it if it must outlive the handle.  The
 *    handler keeps its own reference to the input stream it was opened with;
 *    the caller may close its file descriptor after tz7z_open returns.
 *  - Errors: every exported function catches C++ exceptions; none may cross
 *    this ABI.  On failure the returned code is one of the TZ7Z_E_* values and
 *    err receives a short English diagnostic when the caller supplied a buffer.
 *  - Password: NULL or "" means "no password to offer".  An archive opened
 *    with a password remembers it, so a later extract/modify with "" falls
 *    back to that one.
 *
 * License: the shim is MIT.  The linked 7-Zip library is LGPL-2.1+ / GPL-2.0+.
 */
#ifndef TZ7Z_H
#define TZ7Z_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TZ7Z_OK              0  /* success */
#define TZ7Z_E_ARG          -1  /* bad argument, ABI mismatch, out-of-range index */
#define TZ7Z_E_MEMORY       -2  /* C++ exception (usually allocation) caught at the boundary */
#define TZ7Z_E_OPEN         -3  /* the archive could not be opened (I/O or no handler) */
#define TZ7Z_E_NOT_ARCHIVE  -4  /* no handler recognised the file */
#define TZ7Z_E_PASSWORD     -5  /* a handler asked for a password and the open/extract failed */
#define TZ7Z_E_FORMAT       -6  /* the format cannot do this (e.g. create/update/comment) */
#define TZ7Z_E_UPDATE       -7  /* writing the new archive failed */
#define TZ7Z_E_EXTRACT      -8  /* an entry could not be extracted or tested (data/CRC) */
#define TZ7Z_E_CANCEL       -9  /* the progress callback asked to stop */
#define TZ7Z_E_IO           -10 /* a file could not be read/written/renamed */
#define TZ7Z_E_UNSUPPORTED  -11 /* the format cannot be updated at all */

/* ABI revision of the struct layouts below.  Bump it whenever a field is added,
   removed or reordered.  Every struct that crosses the ABI starts with
   `struct_size` (the caller's sizeof) and `abi_version` (this value); the
   library validates both and rejects a mismatched caller with TZ7Z_E_ARG and a
   readable error instead of writing into a too-small struct. */
/* 3 added tz7z_extract_one_prefix; 4 added the progress-info sink below and
   the *_ex entry points; 5 added tz7z_set_name_codepage; 6 added
   tz7z_entry_name_is_legacy.  The old progress callback and struct layouts are
   unchanged, so old callers keep working against the same symbols. */
#define TZ7Z_ABI_VERSION 6u

typedef struct tz7z_archive tz7z_archive;

typedef struct tz7z_entry_info
{
  uint32_t struct_size;    /* caller sets sizeof(tz7z_entry_info) */
  uint32_t abi_version;    /* caller sets TZ7Z_ABI_VERSION */
  uint64_t size;
  uint64_t packed_size;
  uint64_t mtime;          /* unix seconds, 0 = unknown */
  uint64_t ctime;          /* unix seconds, 0 = unknown */
  uint64_t atime;          /* unix seconds, 0 = unknown */
  uint32_t crc;            /* 0 when absent */
  uint32_t attrib;         /* 7-Zip attribute word (Unix mode at bits 16..31) */
  int32_t  is_dir;
  int32_t  encrypted;
  int32_t  is_anti;
  int32_t  num_streams;
  char     method[64];     /* NUL terminated UTF-8, may be empty */
  char     comment[256];   /* NUL terminated UTF-8, may be empty */
} tz7z_entry_info;

/* One input.  struct_size/abi_version must be filled in every record: the
   library validates each one, so a caller built against another revision gets
   TZ7Z_E_ARG naming the bad record instead of a truncated archive. */
typedef struct tz7z_input
{
  uint32_t    struct_size; /* caller sets sizeof(tz7z_input) */
  uint32_t    abi_version; /* caller sets TZ7Z_ABI_VERSION */
  const char *disk_path;   /* UTF-8 path on disk */
  const char *arc_path;    /* UTF-8 path inside archive, '/' separated */
  int32_t     is_dir;
} tz7z_input;

typedef struct tz7z_create_options
{
  uint32_t    struct_size; /* caller sets sizeof(tz7z_create_options) */
  uint32_t    abi_version; /* caller sets TZ7Z_ABI_VERSION */
  const char *format;      /* handler name: "7z", "zip", "tar", ... */
  int32_t     level;       /* 0..9, -1 = engine default */
  const char *method;      /* "", "LZMA2", "Deflate", ... */
  int32_t     solid;       /* 0 = off, 1 = on; -1 means "engine default" and is
                              meaningful when options==NULL (tz7z_modify) */
  int32_t     threads;     /* 0 = auto */
  const char *password;    /* "" = no password */
  int32_t     encrypt_names; /* 7z only: encrypt header */
  int32_t     zip_aes256;  /* zip only: AES-256 instead of ZipCrypto */
  uint64_t    volume_size; /* 0 = single file, otherwise split volume bytes.
                              Used by tz7z_create and tz7z_modify. */

  /* Advanced settings.  Each is optional: leave unset (0 / NULL / -1) and the
     engine's own default is used, exactly as if the option had not been given. */

  /* LZMA/LZMA2 dictionary size in bytes (0 = engine default). */
  uint64_t    dictionary_size;
  /* PPMd word size in bits (0 = engine default). */
  int32_t     word_size;
  /* Match finder name for LZMA/LZMA2: "bt4", "bt3", "bt2", "hc4", ... */
  const char *match_finder;
  /* Number of optimisation passes for LZMA (0 = engine default). */
  int32_t     num_passes;
  /* ZIP only: code page for non-ASCII entry names (0 = keep the engine default).
     Windows ZIP tools write the local ANSI page (936 = GBK, 932 = Shift-JIS);
     Linux tools write UTF-8.  The reader needs the same setting to undo it. */
  uint32_t    codepage;
  /* ZIP only: 1 = always set the UTF-8 name flag, ignoring codepage. */
  int32_t     force_utf8;
  /* Raw "name=value" pairs, ':' separated.  This is the escape hatch for
     engine options this ABI does not model yet, e.g. "tc=off".  Keys that a
     dedicated field above already sets (mt, x, d, m, pass, mf) are ignored:
     the dedicated field wins, so an extra-option typo cannot silently
     override a real setting. */
  const char *extra_options;

  /* Archive-level comment (UTF-8). NULL leaves the existing one alone; an empty
     string clears it. Honoured by tz7z_modify for ZIP archives; other formats
     ignore it (their engines cannot store one), and tz7z_create ignores it. */
  const char *comment;
  /* 1 = apply `comment` (even when empty, which clears it); 0 = leave it as it
     is. A separate flag because NULL and "" must mean different things and the
     struct is memset to zero by callers. */
  int32_t has_comment;
} tz7z_create_options;

/* 1 = continue, 0 = cancel.  total may be 0 when unknown. */
typedef int (*tz7z_progress_fn)(void *user, uint64_t completed, uint64_t total);

/* Detailed progress, ABI v4.  The old tz7z_progress_fn above still receives the
   same (completed,total) ticks; this sink adds per-item events and the live
   compressed byte count.  A NULL sink (fn == NULL) means "not subscribed". */
#define TZ7Z_PH_OPEN     0u
#define TZ7Z_PH_EXTRACT  1u
#define TZ7Z_PH_CREATE   2u
#define TZ7Z_PH_TEST     3u

#define TZ7Z_EV_TICK      0u
#define TZ7Z_EV_ITEM      1u  /* entering an item; bytes_* are its start snapshot */
#define TZ7Z_EV_ITEM_DONE 2u

typedef struct tz7z_progress_info
{
  uint32_t    struct_size;    /* caller sets sizeof(tz7z_progress_info) */
  uint32_t    abi_version;    /* caller sets TZ7Z_ABI_VERSION */
  uint32_t    phase;          /* TZ7Z_PH_* */
  uint32_t    event;          /* TZ7Z_EV_* */
  uint32_t    item_index;     /* (uint32_t)-1 = unknown */
  uint32_t    item_count;     /* 0 = unknown */
  uint32_t    index_is_arc;   /* 1 = item_index is the archive index */
  int32_t     packed_known;   /* packed_done is valid */
  uint64_t    bytes_done;     /* input/unpacked bytes */
  uint64_t    bytes_total;    /* 0 = unknown */
  uint64_t    packed_done;    /* cumulative packed bytes, when known */
  const char *item_name;      /* UTF-8, valid only during the callback; may be NULL */
} tz7z_progress_info;

typedef int (*tz7z_progress_ex_fn)(void *user,
                                   const tz7z_progress_info *info);

typedef struct tz7z_progress_sink
{
  uint32_t              struct_size;  /* caller sets sizeof(tz7z_progress_sink) */
  uint32_t              abi_version;  /* caller sets TZ7Z_ABI_VERSION */
  tz7z_progress_ex_fn   fn;           /* NULL = not subscribed */
  void                 *user;
} tz7z_progress_sink;

/* The ABI revision this library was built with (TZ7Z_ABI_VERSION).  A loader
 * must compare it with the value it was compiled against and refuse to use a
 * mismatched library before calling anything else. */
uint32_t tz7z_abi_version(void);

/* Formats as a JSON array.  Returns the number of bytes required including NUL.
 * If buffer is non-NULL and capacity is large enough the JSON is copied.
 * Returns -1 when the engine format table could not be loaded (an empty list and
 * a failed load must not look the same). */
int tz7z_format_json(char *buffer, int capacity);

/* Open an archive, auto-detecting the format.  Returns TZ7Z_E_PASSWORD when a
   handler asked for a password and the open failed: either none was supplied
   or the one supplied was wrong.  A file no handler recognises is reported as
   TZ7Z_E_NOT_ARCHIVE. */
int tz7z_open(const char *path, const char *password,
              tz7z_archive **out_archive,
              char *err, int err_capacity);

/* Same as tz7z_open, with an optional detailed-progress sink. */
int tz7z_open_ex(const char *path, const char *password,
                 const tz7z_progress_sink *sink,
                 tz7z_archive **out_archive,
                 char *err, int err_capacity);

/* ZIP only: the code page used for entry names that do NOT carry the UTF-8
   name flag (0x0800).  Call it right after tz7z_open, before reading any
   entry; later calls still affect names not read yet.  0 means "keep the
   engine default" (the historical byte fallback).  Formats other than ZIP
   return TZ7Z_E_FORMAT and behave exactly as before.  Entry names with the
   UTF-8 flag are never affected, and the write side of tz7z_modify takes its
   code page from tz7z_create_options, not from this handle.  ABI v5. */
int tz7z_set_name_codepage(tz7z_archive *archive, uint32_t codepage);

/* ZIP only: 1 when this entry's name had to be decoded through a legacy code
   page (or through the Info-ZIP Unicode name extra field, which the engine
   treats the same way), 0 when it is UTF-8 or ASCII.  This is how the caller
   decides whether rewriting the archive must keep its code page.  Call it
   after tz7z_entry_name for the same index (the name is what records the
   answer), or it decodes the name itself.  ABI v6. */
int tz7z_entry_name_is_legacy(tz7z_archive *archive, uint32_t index);

void tz7z_close(tz7z_archive *archive);

int tz7z_entry_count(tz7z_archive *archive);
/* The handler name ("7z", "zip", ...).  The pointer is owned by the handle and
   stays valid until tz7z_close; it is never a shared static buffer. */
const char *tz7z_format_name(tz7z_archive *archive);
int tz7z_has_encrypted(tz7z_archive *archive);
int tz7z_can_update(tz7z_archive *archive);

/* Get entry name (UTF-8).  Returns required size including NUL. */
int tz7z_entry_name(tz7z_archive *archive, uint32_t index,
                    char *buffer, int capacity);
/* Fills info.  The caller must initialise info->struct_size =
   sizeof(tz7z_entry_info) and info->abi_version = TZ7Z_ABI_VERSION first; a
   mismatched struct is rejected with TZ7Z_E_ARG instead of being written into. */
int tz7z_entry_info_get(tz7z_archive *archive, uint32_t index,
                        tz7z_entry_info *info);

/* The archive-level comment (not an entry's). UTF-8, NUL terminated when it
   fits; returns the required size including NUL, so a caller can size a buffer
   by calling with capacity 0.  Read from the ZIP end-of-central-directory
   record; formats without one answer 1 and an empty string. */
int tz7z_comment(tz7z_archive *archive, char *buffer, int capacity);

/* Set the archive comment. Passing NULL or "" clears it. Only ZIP can store
   one through this ABI: other formats return TZ7Z_E_FORMAT and leave the file
   byte-for-byte untouched.  The comment is written through a sibling temporary
   file and renamed into place, so a failure keeps the previous archive. */
int tz7z_set_comment(tz7z_archive *archive, const char *comment);

/* NOTE: tz7z_set_password was removed in ABI version 2; it had no callers and
   the password handed to tz7z_open/extract/modify is the one that applies. */

/* indices==NULL && count==0 extracts everything.  Duplicate indices are not
   merged; the list is sorted internally, so any order is accepted. */
int tz7z_extract(tz7z_archive *archive,
                 const uint32_t *indices, uint32_t count,
                 const char *out_dir, const char *password,
                 tz7z_progress_fn progress, void *user,
                 char *err, int err_capacity);

int tz7z_extract_ex(tz7z_archive *archive,
                    const uint32_t *indices, uint32_t count,
                    const char *out_dir, const char *password,
                    tz7z_progress_fn progress, void *user,
                    const tz7z_progress_sink *sink,
                    char *err, int err_capacity);

int tz7z_test(tz7z_archive *archive, const uint32_t *indices, uint32_t count,
              const char *password, tz7z_progress_fn progress, void *user,
              char *err, int err_capacity);

int tz7z_test_ex(tz7z_archive *archive, const uint32_t *indices, uint32_t count,
                 const char *password, tz7z_progress_fn progress, void *user,
                 const tz7z_progress_sink *sink,
                 char *err, int err_capacity);

/* Extract one entry to an exact file path, creating parents as needed. */
int tz7z_extract_one(tz7z_archive *archive, uint32_t index,
                     const char *out_file, const char *password,
                     tz7z_progress_fn progress, void *user,
                     char *err, int err_capacity);

/* Extract at most max_bytes of one entry into out_file.  The decoder is stopped
 * as soon as the limit is reached and the call reports success: out_file holds
 * the prefix (it is shorter than the entry).  max_bytes == 0 means "no limit"
 * and behaves exactly like tz7z_extract_one.  There is no progress callback;
 * this is meant for previewing a large entry without materialising it.  An
 * index outside the archive is TZ7Z_E_ARG. */
int tz7z_extract_one_prefix(tz7z_archive *archive, uint32_t index,
                            const char *out_file, const char *password,
                            uint64_t max_bytes, char *err, int err_capacity);

int tz7z_create(const char *archive_path, const tz7z_create_options *options,
                const tz7z_input *inputs, uint32_t count,
                tz7z_progress_fn progress, void *user,
                char *err, int err_capacity);

int tz7z_create_ex(const char *archive_path, const tz7z_create_options *options,
                   const tz7z_input *inputs, uint32_t count,
                   tz7z_progress_fn progress, void *user,
                   const tz7z_progress_sink *sink,
                   char *err, int err_capacity);

/* Rebuild an existing archive, removing indices and/or adding inputs.
 * The archive is replaced atomically through a unique sibling temporary file:
 * any failure (including a failed flush/close) leaves the previous archive
 * untouched.  A split set (opened through its ".001" part) needs a volume_size
 * and is rebuilt as a set; without one the call fails with TZ7Z_E_ARG instead
 * of collapsing the set and orphaning the other parts. */
int tz7z_modify(const char *archive_path, const char *password,
                const tz7z_create_options *options,
                const uint32_t *remove_indices, uint32_t remove_count,
                const tz7z_input *add_inputs, uint32_t add_count,
                tz7z_progress_fn progress, void *user,
                char *err, int err_capacity);

int tz7z_modify_ex(const char *archive_path, const char *password,
                   const tz7z_create_options *options,
                   const uint32_t *remove_indices, uint32_t remove_count,
                   const tz7z_input *add_inputs, uint32_t add_count,
                   tz7z_progress_fn progress, void *user,
                   const tz7z_progress_sink *sink,
                   char *err, int err_capacity);

#ifdef __cplusplus
}
#endif

#endif
