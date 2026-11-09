{ Keep a Cocoa form from scrolling its own content.

  LCL wraps every form in an NSScrollView.  Even with TForm.AutoScroll=False
  (and LCL reporting scrollbar range 0), the clip view can move its bounds origin
  -- in this app exactly the title-bar height -- so one wheel tick shifts the
  whole form surface and pushes the status bar off screen.

  AutoScroll does not stop that.  The fix is native: pin the document view to
  the clip size, and observe NSViewBoundsDidChangeNotification on the clip view
  so a moved origin is put back in the same event cycle (a timer would be
  visible as a jump-back).  Child controls keep their own scrolling: the
  observer only touches the form's own clip view. }
unit tzip.ui.scrollguard;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}{$modeswitch objectivec1}{$ENDIF}

interface

uses
  Forms;

{ Pin AForm's Cocoa document view to its clip size and keep the clip origin at
  zero.  No-op on non-Darwin targets and before the handle exists. }
procedure TzGuardFormScroll(AForm: TCustomForm);

{ Undo TzGuardFormScroll's observer registration before the form is destroyed. }
procedure TzUnguardFormScroll(AForm: TCustomForm);

implementation

{$IFDEF DARWIN}
uses
  Classes, CocoaAll;

type
  TTzScrollKeeper = objcclass(NSObject)
  public
    procedure clipBoundsChanged(note: NSNotification);
      message 'clipBoundsChanged:';
  end;

var
  GKeeper: TTzScrollKeeper = nil;
  GClips: TList = nil;

procedure TTzScrollKeeper.clipBoundsChanged(note: NSNotification);
var
  Clip: NSClipView;
begin
  if note = nil then Exit;
  Clip := NSClipView(note.object_);
  if Clip = nil then Exit;
  if (Clip.bounds.origin.x <> 0) or (Clip.bounds.origin.y <> 0) then
    Clip.setBoundsOrigin(NSZeroPoint);
end;

procedure TzGuardFormScroll(AForm: TCustomForm);
var
  SV: NSScrollView;
  DV: NSView;
  Clip: NSClipView;
  S: NSSize;
begin
  if (AForm = nil) or (not AForm.HandleAllocated) then Exit;
  SV := NSScrollView(AForm.Handle);
  if SV = nil then Exit;
  DV := SV.documentView;
  if DV = nil then Exit;
  S := SV.contentSize;
  if (DV.frame.size.width <> S.width) or (DV.frame.size.height <> S.height) then
    DV.setFrameSize(S);
  Clip := SV.contentView;
  if Clip = nil then Exit;
  if GKeeper = nil then GKeeper := TTzScrollKeeper.alloc.init;
  if GClips = nil then GClips := TList.Create;
  Clip.setPostsBoundsChangedNotifications(True);
  if GClips.IndexOf(Clip) < 0 then
  begin
    NSNotificationCenter.defaultCenter.addObserver_selector_name_object(
      GKeeper, objcselector('clipBoundsChanged:'),
      NSViewBoundsDidChangeNotification, Clip);
    GClips.Add(Clip);
  end;
  if (Clip.bounds.origin.x <> 0) or (Clip.bounds.origin.y <> 0) then
    Clip.setBoundsOrigin(NSZeroPoint);
end;

procedure TzUnguardFormScroll(AForm: TCustomForm);
var
  SV: NSScrollView;
  Clip: NSClipView;
  I: Integer;
begin
  if (AForm = nil) or (not AForm.HandleAllocated) or (GClips = nil) then Exit;
  SV := NSScrollView(AForm.Handle);
  if SV = nil then Exit;
  Clip := SV.contentView;
  if Clip = nil then Exit;
  I := GClips.IndexOf(Clip);
  if I < 0 then Exit;
  NSNotificationCenter.defaultCenter.removeObserver_name_object(
    GKeeper, NSViewBoundsDidChangeNotification, Clip);
  GClips.Delete(I);
end;
{$ELSE}
procedure TzGuardFormScroll(AForm: TCustomForm);
begin
end;

procedure TzUnguardFormScroll(AForm: TCustomForm);
begin
end;
{$ENDIF}

end.
