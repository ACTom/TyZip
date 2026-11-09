{ The preview pane's text side: the two viewers, their bar, and the title/hint.

  Everything here was the window's code: two read-only SynEdits (plain and always
  wrapped), the encoding / word-wrap / language controls, the title band and the
  "nothing selected" hint. The image viewer is still in the window for now; the
  pane exposes its bar and blank panel so the image controls can be parented into
  the same place they have always been.

  Layer: LCL view. The preview session (decoding, limits, zoom arithmetic) is in
  tzip.preview.session; lifetime (workers, timers, temp files) stays in the window. }

unit tzip.preview.pane;

{$mode objfpc}{$H+}
{$WARN 5079 OFF} { SynEditWrappedView is experimental but is the supported wrap view }

interface

uses
  Classes, SysUtils, Graphics, Controls, StdCtrls, ExtCtrls, Forms,
  BGRABitmap, BGRABitmapTypes,
  SynEdit, SynEditTypes, SynEditHighlighter, SynEditWrappedView,
  tyControls.Types, tyControls.Controller, tyControls.Panel, tyControls.TyLabel,
  tyControls.GlyphButtons, tyControls.ComboBox,
  tzip.i18n, tzip.preview, tzip.preview.session;

type
  TPreviewPane = class(TTyPanel)
  private
    FTitle: TTyLabel;
    FHint: TTyLabel;
    FEdit: TSynEdit;
    FWrapEdit: TSynEdit;
    FBar: TTyPanel;
    FEncCombo: TTyComboBox;
    FWrapBtn: TTyGlyphButton;
    FLangCombo: TTyComboBox;
    FRaw: TBytes;
    FName: string;
    FEncIndex: Integer;
    FEncGuard: Boolean;
    FLanguage: Integer;
    FLangGuard: Boolean;
    FHighlighter: TSynCustomHighlighter;
    FHighlighter2: TSynCustomHighlighter;
    FIsText: Boolean;
    { The image viewer: the picture control, the original pixels the zoom
      re-samples from, and the drag/zoom state. }
    FImage: TImage;
    FImageSource: TBGRABitmap;
    FImageZoom: Double;
    FImagePanX, FImagePanY: Integer;
    FDragActive: Boolean;
    FWheelAccum: Integer;
    FDragStart: TPoint;
    FZoomLabel: TTyLabel;
    FZoomFitBtn, FZoomInBtn, FZoomOutBtn, FZoomOneBtn: TTyGlyphButton;
    procedure SetupEditor(AEdit: TSynEdit);
    procedure RefreshText;
    procedure SetHighlighter;
    procedure UpdateEditorVisibility;
    function  ActiveEditor: TSynEdit;
    procedure EncChange(Sender: TObject);
    procedure WrapClick(Sender: TObject);
    procedure LanguageChange(Sender: TObject);
    procedure SelectLanguage(AIndex: Integer);
    procedure HideTextForImage;
    procedure LayoutZoomBar;
    procedure ApplyImageZoomCore(ACentre: Boolean);
    procedure ApplyImageZoom;
    procedure CentrePreviewImage;
    function  PreviewImageAreaW: Integer;
    function  PreviewImageAreaH: Integer;
    function  PreviewImageAreaTop: Integer;
    procedure SetImageZoomAt(AZoom: Double; AAnchorX, AAnchorY: Integer);
    procedure SetImageZoom(AZoom: Double);
    function  RestingImageX: Integer;
    function  RestingImageY: Integer;
    procedure ScaleImageZoom(AFactor: Double);
    function  ImageFitZoom: Double;
    procedure ZoomInClick(Sender: TObject);
    procedure ZoomOutClick(Sender: TObject);
    procedure ZoomOneClick(Sender: TObject);
    procedure ZoomFitClick(Sender: TObject);
    procedure ImageMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure ImageMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure ImageMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure ImageWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
  public
    destructor Destroy; override;
    procedure Resize; override;
    constructor Create(AOwner: TComponent); reintroduce;
    { Show AName's already-read bytes. The caller keeps reading files and deciding
      whether text is worth showing; the pane decides how text is displayed.
      AEncIndex comes from the caller so the auto-detect happens once per file. }
    procedure ShowText(const AName: string; const ARaw: TBytes; AEncIndex: Integer;
      ATruncated: Boolean);
    { Nothing to show: hide the viewers and the bar, centre AText. }
    procedure ShowHintText(const AText: string);
    { Forget the current text and free its highlighters. }
    procedure ClearText;
    { Show only the controls that belong to text; the caller toggles its own
      image controls in the same bar. }
    procedure SetTextBarMode(AText: Boolean);
    { Show a decoded picture. The pane takes ownership of ABitmap. }
    procedure ShowImage(ABitmap: TBGRABitmap; const AName: string);
    { Hide the picture and drop the decoded pixels. }
    procedure ClearImage;
    { Show/hide the controls that belong to text vs image in the shared bar. }
    procedure SetBarMode(AText: Boolean);
    { True for the pane's own text controls, so the window can keep navigation
      shortcuts from stealing keystrokes meant for them. }
    function IsTextInput(AControl: TControl): Boolean;
    { Recolour the viewers and highlighters from the current theme. }
    procedure ApplyThemePalette;
    property Bar: TTyPanel read FBar;
    property HintLabel: TTyLabel read FHint;
    property TitleLabel: TTyLabel read FTitle;
    property EncCombo: TTyComboBox read FEncCombo;
    property WrapButton: TTyGlyphButton read FWrapBtn;
    property LangCombo: TTyComboBox read FLangCombo;
    property IsText: Boolean read FIsText;
  end;

implementation

constructor TPreviewPane.Create(AOwner: TComponent);
var
  I: Integer;
begin
  inherited Create(AOwner);
  Align := alRight;
  Width := 320;
  { No Name on a caption-less panel. TControl.Caption falls back to the
    component Name when the caption is empty, and TTyPanel paints its Caption:
    naming this panel literally drew "PreviewPanel" on top of the hint text
    whenever nothing was selected. }
  Caption := '';

  FTitle := TTyLabel.Create(Self);
  FTitle.Parent := Self;
  FTitle.Align := alTop;
  { Same band height as the file list's column header, so the three panes start
    their content on one line. 30 px (a heading) left the preview's first text a
    header below the list's first row. }
  FTitle.Height := 24;
  FTitle.Caption := rsPreviewTitle;
  FTitle.StyleClass := 'muted';
  { TTyLabel has no horizontal padding in the built-in theme; a per-instance
    style patch keeps the heading off the pane border without wrapping it in a
    second padded container. }
  FTitle.StyleOverride :=
    'padding: 0px 10px 0px 12px; background: var(--surface-chrome);';
  FTitle.Name := 'PreviewTitle';

  FHint := TTyLabel.Create(Self);
  FHint.Parent := Self;
  FHint.Align := alClient;
  FHint.Alignment := taCenter;
  FHint.Layout := tlCenter;
  FHint.WordWrap := True;
  FHint.BorderSpacing.Around := 12;
  FHint.Caption := rsPreviewNoSelection;
  FHint.StyleClass := 'muted';
  FHint.StyleOverride := 'padding: 12px;';
  FHint.Name := 'PreviewHint';

  { Text viewer. A read-only SynEdit rather than a memo: the user asked for
    editor behaviour (click past the end of a line, line numbers, selection,
    syntax highlighting) and a themed palette that follows the app's light/dark
    mode. BorderSpacing keeps it off the pane edge.
    Two viewers exist: the plain one and one that always wraps. }
  FEdit := TSynEdit.Create(Self);
  FEdit.Parent := Self;
  SetupEditor(FEdit);
  FEdit.Name := 'PreviewEdit';

  FWrapEdit := TSynEdit.Create(Self);
  FWrapEdit.Parent := Self;
  SetupEditor(FWrapEdit);
  FWrapEdit.ScrollBars := ssAutoVertical;
  FWrapEdit.Name := 'PreviewWrapEdit';
  { Created once and kept for the editor's lifetime; the wrap toggle switches
    between the two viewers instead of adding/removing this view. }
  TLazSynEditLineWrapPlugin.Create(FWrapEdit);

  { Bottom bar of the preview pane: encoding / word wrap / syntax highlighting.
    It only appears while a text preview is on screen. The image controls share
    this bar; the owner adds them. }
  FBar := TTyPanel.Create(Self);
  FBar.Parent := Self;
  FBar.Align := alBottom;
  FBar.Height := 34;
  FBar.Caption := '';
  FBar.Visible := False;
  FBar.StyleOverride :=
    'padding: 0px; background: var(--surface-chrome); border: none;';

  FEncCombo := TTyComboBox.Create(Self);
  FEncCombo.Parent := FBar;
  FEncCombo.Style := csDropDownList;
  FEncCombo.Left := 8;
  FEncCombo.Top := 5;
  FEncCombo.Width := 128;
  FEncCombo.Height := 24;
  FEncCombo.Anchors := [akLeft, akTop];
  { The image controls take the first five tab slots, so text keeps 5..7 exactly
    as it did when all of them were created in one place. }
  FEncCombo.TabOrder := 5;
  FEncCombo.OnChange := @EncChange;
  FEncCombo.Name := 'PreviewEncCombo';
  for I := 0 to PreviewEncodingCount - 1 do
    FEncCombo.Items.Add(PreviewEncodings[I].LabelText);

  { Created right-to-left: the first alRight child ends up right-most.
    A language PICKER, not a toggle: the extension guess is only a guess, and a
    user who sees the wrong colours needs to name the language rather than turn
    highlighting off. "None" is the first entry and means plain text. }
  FLangCombo := TTyComboBox.Create(Self);
  FLangCombo.Parent := FBar;
  FLangCombo.Style := csDropDownList;
  FLangCombo.Width := 118;
  FLangCombo.Height := 24;
  FLangCombo.Top := 5;
  FLangCombo.Hint := rsPreviewSyntaxHint;
  FLangCombo.ShowHint := True;
  FLangCombo.Anchors := [akTop, akRight];
  FLangCombo.AnchorSide[akRight].Control := FBar;
  FLangCombo.AnchorSide[akRight].Side := asrRight;
  FLangCombo.BorderSpacing.Right := 6;
  FLangCombo.TabOrder := 6;
  FLangCombo.OnChange := @LanguageChange;
  FLangCombo.Name := 'PreviewLangCombo';
  for I := 0 to TzPreviewLanguageCount - 1 do
    FLangCombo.Items.Add(TzPreviewLanguageName(I));

  FWrapBtn := TTyGlyphButton.Create(Self);
  FWrapBtn.Parent := FBar;
  FWrapBtn.Caption := rsPreviewWrap;
  FWrapBtn.ShowCaption := True;
  FWrapBtn.StyleClass := 'ghost';
  FWrapBtn.AutoSize := False;
  FWrapBtn.Width := 64;
  FWrapBtn.Hint := rsPreviewWrapHint;
  FWrapBtn.ShowHint := True;
  FWrapBtn.Height := 26;
  FWrapBtn.Top := 4;
  FWrapBtn.Anchors := [akTop, akRight];
  FWrapBtn.AnchorSide[akRight].Control := FLangCombo;
  FWrapBtn.AnchorSide[akRight].Side := asrLeft;
  FWrapBtn.BorderSpacing.Right := 4;
  FWrapBtn.TabOrder := 7;
  FWrapBtn.OnClick := @WrapClick;
  FWrapBtn.Name := 'PreviewWrapBtn';

  { Zoom controls, right to left in the bar: the image's main interaction. The
    corners of the bar are the text controls, so this group is centred; the tab
    slots 0..4 are theirs, text keeps 5..7. }
  FZoomOneBtn := TTyGlyphButton.Create(Self);
  FZoomOneBtn.Parent := FBar;
  FZoomOneBtn.Caption := '1:1';
  FZoomOneBtn.ShowCaption := True;
  FZoomOneBtn.StyleClass := 'ghost';
  FZoomOneBtn.AutoSize := False;
  FZoomOneBtn.Width := 42;
  FZoomOneBtn.Height := 26;
  FZoomOneBtn.Top := 4;
  FZoomOneBtn.TabOrder := 0;
  FZoomOneBtn.Anchors := [akTop];
  FZoomOneBtn.OnClick := @ZoomOneClick;

  FZoomInBtn := TTyGlyphButton.Create(Self);
  FZoomInBtn.Parent := FBar;
  FZoomInBtn.Caption := '+';
  FZoomInBtn.ShowCaption := True;
  FZoomInBtn.StyleClass := 'ghost';
  FZoomInBtn.AutoSize := False;
  FZoomInBtn.Width := 30;
  FZoomInBtn.Height := 26;
  FZoomInBtn.Top := 4;
  FZoomInBtn.TabOrder := 1;
  FZoomInBtn.Anchors := [akTop];
  FZoomInBtn.OnClick := @ZoomInClick;

  FZoomOutBtn := TTyGlyphButton.Create(Self);
  FZoomOutBtn.Parent := FBar;
  FZoomOutBtn.Caption := '−';
  FZoomOutBtn.ShowCaption := True;
  FZoomOutBtn.StyleClass := 'ghost';
  FZoomOutBtn.AutoSize := False;
  FZoomOutBtn.Width := 30;
  FZoomOutBtn.Height := 26;
  FZoomOutBtn.Top := 4;
  FZoomOutBtn.TabOrder := 2;
  FZoomOutBtn.Anchors := [akTop];
  FZoomOutBtn.OnClick := @ZoomOutClick;

  FZoomFitBtn := TTyGlyphButton.Create(Self);
  FZoomFitBtn.Parent := FBar;
  FZoomFitBtn.Caption := rsZoomFit;
  FZoomFitBtn.ShowCaption := True;
  FZoomFitBtn.StyleClass := 'ghost';
  FZoomFitBtn.AutoSize := False;
  FZoomFitBtn.Width := 46;
  FZoomFitBtn.Height := 26;
  FZoomFitBtn.Top := 4;
  FZoomFitBtn.TabOrder := 3;
  FZoomFitBtn.Anchors := [akTop];
  FZoomFitBtn.OnClick := @ZoomFitClick;

  FZoomLabel := TTyLabel.Create(Self);
  FZoomLabel.Parent := FBar;
  FZoomLabel.Caption := '';
  FZoomLabel.StyleClass := 'muted';
  FZoomLabel.AutoSize := False;
  FZoomLabel.Width := 48;
  FZoomLabel.Height := 26;
  FZoomLabel.Top := 4;
  FZoomLabel.Alignment := taCenter;
  FZoomLabel.Layout := tlCenter;
  FZoomLabel.Anchors := [akTop];
  FZoomLabel.StyleOverride := 'background: transparent;';

  FImage := TImage.Create(Self);
  { The image sits directly in the pane so it can be larger than the pane and be
    dragged around; TImage on its own can only scale to fit. }
  FImage.Parent := Self;
  { alNone with an explicit size, NOT alClient: the point of zooming is to see the
    image larger than the pane, and an aligned child is always clipped to its
    parent's client rect. Centred by hand whenever the pane or the zoom changes. }
  FImage.Align := alNone;
  FImage.Center := False;
  FImage.Proportional := True;
  { Stretch lets the control draw its picture into its own rectangle, so zooming is
    a resize plus one scaled paint -- no intermediate bitmap per step. }
  FImage.Stretch := True;
  FImage.Visible := False;
  FImage.Cursor := crSizeAll;
  FImage.OnMouseDown := @ImageMouseDown;
  FImage.OnMouseMove := @ImageMouseMove;
  FImage.OnMouseUp := @ImageMouseUp;
  FImage.OnMouseWheel := @ImageWheel;
  FImage.Name := 'PreviewImage';

  LayoutZoomBar;
end;

destructor TPreviewPane.Destroy;
begin
  FreeAndNil(FImageSource);
  inherited Destroy;
end;

procedure TPreviewPane.Resize;
begin
  inherited Resize;
  if FBar <> nil then LayoutZoomBar;
  { Keep a zoomed picture centred/covered after the pane changes width. }
  if (FImageSource <> nil) and (FImage <> nil) and FImage.Visible then
    CentrePreviewImage;
end;

procedure TPreviewPane.HideTextForImage;
begin
  FIsText := False;
  if FEdit <> nil then FEdit.Visible := False;
  if FWrapEdit <> nil then FWrapEdit.Visible := False;
end;

procedure TPreviewPane.SetBarMode(AText: Boolean);
begin
  if FBar = nil then Exit;
  SetTextBarMode(AText);
  if FZoomFitBtn <> nil then FZoomFitBtn.Visible := not AText;
  if FZoomOutBtn <> nil then FZoomOutBtn.Visible := not AText;
  if FZoomInBtn <> nil then FZoomInBtn.Visible := not AText;
  if FZoomOneBtn <> nil then FZoomOneBtn.Visible := not AText;
  if FZoomLabel <> nil then FZoomLabel.Visible := not AText;
  if not AText then LayoutZoomBar;
end;

procedure TPreviewPane.ShowImage(ABitmap: TBGRABitmap; const AName: string);
begin
  { The decoded pixels, kept as the zoom reference AND handed to the control once.
    The conversion to LCL's bitmap happens here, not per zoom step: that is the
    whole point of stretching in the paint. }
  FreeAndNil(FImageSource);
  FImageSource := ABitmap;
  FImage.Picture.Bitmap.PixelFormat := pf32bit;
  FImage.Picture.Bitmap.SetSize(ABitmap.Width, ABitmap.Height);
  ABitmap.Draw(FImage.Picture.Bitmap.Canvas, 0, 0, False);
  HideTextForImage;
  { The bar carries the zoom controls now, so it stays for images too. It is
    shown BEFORE the first fit, because the fit measures the area it leaves. }
  if FBar <> nil then
  begin
    FBar.Visible := True;
    SetBarMode(False);
  end;
  if FHint <> nil then FHint.Visible := False;
  FImage.Visible := True;
  FImageZoom := ImageFitZoom;
  FImagePanX := 0;
  FImagePanY := 0;
  ApplyImageZoom;
  FImage.Invalidate;
end;

procedure TPreviewPane.ClearImage;
begin
  if FImage <> nil then
  begin
    FImage.Visible := False;
    FImage.Picture.Clear;
  end;
  FreeAndNil(FImageSource);
end;

procedure TPreviewPane.LayoutZoomBar;
var
  W, X: Integer;
begin
  if (FBar = nil) or (FZoomFitBtn = nil) then Exit;
  W := FZoomOutBtn.Width + 2 + FZoomInBtn.Width + 2 + FZoomFitBtn.Width + 2 +
       FZoomOneBtn.Width;
  X := (FBar.ClientWidth - W - FZoomLabel.Width - 6) div 2;
  if X < 4 then X := 4;
  FZoomOutBtn.Left := X;
  FZoomInBtn.Left := FZoomOutBtn.Left + FZoomOutBtn.Width + 2;
  FZoomFitBtn.Left := FZoomInBtn.Left + FZoomInBtn.Width + 2;
  FZoomOneBtn.Left := FZoomFitBtn.Left + FZoomFitBtn.Width + 2;
  FZoomLabel.Left := FZoomOneBtn.Left + FZoomOneBtn.Width + 6;
end;

procedure TPreviewPane.ApplyImageZoomCore(ACentre: Boolean);
var
  W, H: Integer;
begin
  if (FImage = nil) or (FImageSource = nil) then Exit;
  W := Round(FImageSource.Width * FImageZoom);
  H := Round(FImageSource.Height * FImageZoom);
  if W < 1 then W := 1;
  if H < 1 then H := 1;
  FImage.Width := W;
  FImage.Height := H;
  if ACentre then CentrePreviewImage;
  FImage.Invalidate;
end;

procedure TPreviewPane.ApplyImageZoom;
begin
  ApplyImageZoomCore(True);
  if FZoomLabel <> nil then
    FZoomLabel.Caption := ZoomPercentText(FImageZoom);
end;

procedure TPreviewPane.CentrePreviewImage;
var
  AW, AH, W, H, X, Y: Integer;
begin
  if (FImage = nil) or (FImage.Parent = nil) then Exit;
  AW := PreviewImageAreaW;
  AH := PreviewImageAreaH;
  if (AW <= 0) or (AH <= 0) then Exit;
  W := FImage.Width;
  H := FImage.Height;
  X := ClampImagePos(W, AW, RestingImageX + FImagePanX);
  Y := ClampImagePos(H, AH, RestingImageY + FImagePanY);
  FImagePanX := X - RestingImageX;
  FImagePanY := Y - RestingImageY;
  FImage.Left := X;
  FImage.Top := PreviewImageAreaTop + Y;
end;

function TPreviewPane.PreviewImageAreaW: Integer;
begin
  Result := 0;
  if FImage = nil then Exit;
  Result := FImage.Parent.ClientWidth;
end;

function TPreviewPane.PreviewImageAreaH: Integer;
var
  HeadH, FootH: Integer;
begin
  Result := 0;
  if FImage = nil then Exit;
  HeadH := 0;
  if FTitle <> nil then HeadH := FTitle.Height;
  FootH := 0;
  if (FBar <> nil) and FBar.Visible then FootH := FBar.Height;
  Result := FImage.Parent.ClientHeight - HeadH - FootH;
end;

function TPreviewPane.PreviewImageAreaTop: Integer;
begin
  Result := 0;
  if FTitle <> nil then Result := FTitle.Height;
end;

procedure TPreviewPane.SetImageZoomAt(AZoom: Double; AAnchorX, AAnchorY: Integer);
var
  Old: Double;
  CurX, CurY: Integer;
begin
  AZoom := ClampImageZoom(AZoom);
  if Abs(AZoom - FImageZoom) < 0.0005 then Exit;
  Old := FImageZoom;
  { Absolute top-left of the picture in pane coordinates, before the change. }
  CurX := FImage.Left;
  CurY := FImage.Top - PreviewImageAreaTop;
  FImageZoom := AZoom;
  ApplyImageZoomCore(False);
  FImagePanX := ZoomedAnchorPan(AAnchorX, CurX, RestingImageX, Old, AZoom);
  FImagePanY := ZoomedAnchorPan(AAnchorY, CurY, RestingImageY, Old, AZoom);
  CentrePreviewImage;
  FImage.Invalidate;
  if FZoomLabel <> nil then
    FZoomLabel.Caption := ZoomPercentText(FImageZoom);
end;

procedure TPreviewPane.SetImageZoom(AZoom: Double);
begin
  SetImageZoomAt(AZoom, PreviewImageAreaW div 2, PreviewImageAreaH div 2);
end;

function TPreviewPane.RestingImageX: Integer;
begin
  Result := ImageRestingPos(FImage.Width, PreviewImageAreaW);
end;

function TPreviewPane.RestingImageY: Integer;
begin
  Result := ImageRestingPos(FImage.Height, PreviewImageAreaH);
end;

procedure TPreviewPane.ScaleImageZoom(AFactor: Double);
begin
  SetImageZoom(FImageZoom * AFactor);
end;

function TPreviewPane.ImageFitZoom: Double;
var
  AW, AH: Integer;
begin
  Result := 1.0;
  if (FImageSource = nil) or (FImage = nil) then Exit;
  if (FImageSource.Width <= 0) or (FImageSource.Height <= 0) then Exit;
  { Fit to the PANE, not to the image control (which is about to be resized to the
    scaled picture and would otherwise feed its own size back in). A little air so
    the edges are visibly inside the pane rather than touching it. }
  if FImage.Parent <> nil then
  begin
    AW := FImage.Parent.ClientWidth - ImageFitMargin;
    AH := FImage.Parent.ClientHeight - ImageFitMargin;
  end
  else
  begin
    AW := 0;
    AH := 0;
  end;
  Result := ImageFitZoomFor(FImageSource.Width, FImageSource.Height, AW, AH);
end;

procedure TPreviewPane.ZoomInClick(Sender: TObject);
begin
  ScaleImageZoom(ZoomButtonStep);
end;

procedure TPreviewPane.ZoomOutClick(Sender: TObject);
begin
  ScaleImageZoom(1 / ZoomButtonStep);
end;

procedure TPreviewPane.ZoomOneClick(Sender: TObject);
begin
  SetImageZoom(1.0);
end;

procedure TPreviewPane.ZoomFitClick(Sender: TObject);
begin
  FImageZoom := ImageFitZoom;
  FImagePanX := 0;
  FImagePanY := 0;
  ApplyImageZoom;
end;

procedure TPreviewPane.ImageMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbLeft then Exit;
  FDragActive := True;
  { Remember the pointer in PANE coordinates. Control coordinates move with the
    control, so a delta taken in them is measured from a frame that is itself
    moving -- the classic cause of an image that runs away from the cursor. }
  FDragStart := FImage.Parent.ScreenToClient(Mouse.CursorPos);
  FImage.Cursor := crHandPoint;
end;

procedure TPreviewPane.ImageMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  Now: TPoint;
begin
  if not FDragActive then Exit;
  Now := FImage.Parent.ScreenToClient(Mouse.CursorPos);
  FImagePanX := FImagePanX + (Now.X - FDragStart.X);
  FImagePanY := FImagePanY + (Now.Y - FDragStart.Y);
  FDragStart := Now;
  CentrePreviewImage;
end;

procedure TPreviewPane.ImageMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  FDragActive := False;
  if FImage <> nil then FImage.Cursor := crSizeAll;
end;

procedure TPreviewPane.ImageWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  Anchor: TPoint;
begin
  { The pointer is the anchor: whatever pixel is under it stays under it as the
    picture grows. The coordinates come from Mouse.CursorPos, not from the event's
    MousePos: that one is expressed in the CONTROL's client area, and the control is
    the picture, so it moves with every zoom step -- feeding it back as an anchor
    made the image chase its own frame. CursorPos is in screen space and is the
    same for every event. }
  Anchor := FImage.Parent.ScreenToClient(Mouse.CursorPos);
  Inc(FWheelAccum, WheelDelta);
  while FWheelAccum >= 120 do
  begin
    Dec(FWheelAccum, 120);
    SetImageZoomAt(FImageZoom * ZoomWheelStep, Anchor.X, Anchor.Y);
  end;
  while FWheelAccum <= -120 do
  begin
    Inc(FWheelAccum, 120);
    SetImageZoomAt(FImageZoom / ZoomWheelStep, Anchor.X, Anchor.Y);
  end;
  Handled := True;
end;

{ Appearance and behaviour shared by both preview viewers. }
procedure TPreviewPane.SetupEditor(AEdit: TSynEdit);
begin
  AEdit.Align := alClient;
  { Flush to the pane. The 6 px ring around the editor showed the pane's own
    background as a grey border between the line-number gutter (which is coloured
    by the editor) and the pane edge, so the gutter looked like a white strip
    floating on grey. }
  AEdit.BorderStyle := bsNone;
  AEdit.ReadOnly := True;
  AEdit.ScrollBars := ssAutoBoth;
  AEdit.TabWidth := 4;
  { A read-only VIEWER, not an editor.

    eoScrollPastEol is deliberately absent: it lets the caret, selection and
    horizontal scroll run past the end of the text into blank space, which in a
    viewer is just somewhere to get lost. Clicking at the end of a line still puts
    the caret at the end of that line; it simply stops there.

    eoKeepCaretX is what keeps the caret in its column while arrowing through
    lines of different lengths, which is worth having even here. }
  AEdit.Options := [eoKeepCaretX, eoHideRightMargin,
    eoScrollPastEof, eoBracketHighlight];
  AEdit.Options2 := [];
  AEdit.Gutter.Visible := True;
  AEdit.Gutter.AutoSize := True;
  { SynEdit's gutter is sized from the digit count alone, so the numbers ended up
    touching the first character of a line. Give the column a little air. }
  AEdit.Gutter.LeftOffset := 6;
  AEdit.Gutter.RightOffset := 8;
  AEdit.Gutter.Parts[0].Visible := False;   { change marks }
  AEdit.Gutter.Parts[1].Visible := True;    { line numbers }
  { SynEdit ships SynDefaultFontQuality = fqNonAntialiased and copies it into the
    editor's Font, so the preview was the one place in the app with jagged text.
    Cocoa maps fqDefault/fqAntialiased to normal font smoothing. }
  AEdit.Font.Quality := fqDefault;
  AEdit.Visible := False;
end;

function TPreviewPane.ActiveEditor: TSynEdit;
begin
  if (FWrapBtn <> nil) and FWrapBtn.Down then
    Result := FWrapEdit
  else
    Result := FEdit;
end;

procedure TPreviewPane.RefreshText;
var
  Txt: string;
begin
  if FEdit = nil then Exit;
  Txt := TzDecodePreviewText(Pointer(FRaw), Length(FRaw), FEncIndex);
  FEdit.Lines.BeginUpdate;
  try
    FEdit.Lines.Text := Txt;
  finally
    FEdit.Lines.EndUpdate;
  end;
  if FWrapEdit <> nil then
  begin
    FWrapEdit.Lines.BeginUpdate;
    try
      FWrapEdit.Lines.Text := Txt;
    finally
      FWrapEdit.Lines.EndUpdate;
    end;
  end;
  { Start at the top-left corner like a fresh viewer, not where the previous
    file was scrolled to. }
  FEdit.CaretXY := Point(1, 1);
  FEdit.TopLine := 1;
  FEdit.LeftChar := 1;
  if FWrapEdit <> nil then
  begin
    FWrapEdit.CaretXY := Point(1, 1);
    FWrapEdit.TopLine := 1;
    FWrapEdit.LeftChar := 1;
  end;
end;

procedure TPreviewPane.ShowText(const AName: string; const ARaw: TBytes;
  AEncIndex: Integer; ATruncated: Boolean);
begin
  if FEdit = nil then Exit;
  FRaw := Copy(ARaw);
  FName := AName;
  FEncIndex := AEncIndex;
  FEncGuard := True;
  try
    if FEncCombo <> nil then FEncCombo.ItemIndex := FEncIndex;
  finally
    FEncGuard := False;
  end;
  { The extension is only a guess; the picker shows it and the user can change it
    for this file. A NEW file always starts from the guess, so switching files does
    not keep the previous file's manual choice. }
  { Decoding or SynEdit can still throw on hostile content; the preview is a
    convenience, so it must degrade to a hint instead of an unhandled exception. }
  try
    FLanguage := TzPreviewLanguageForFile(AName);
    SelectLanguage(FLanguage);
    SetHighlighter;
    RefreshText;
    if ATruncated then
    begin
      FEdit.Lines.Add('');
      FEdit.Lines.Add(rsPreviewTruncated);
      FWrapEdit.Lines.Add('');
      FWrapEdit.Lines.Add(rsPreviewTruncated);
    end;
  except
    on E: Exception do
    begin
      ClearText;
      ShowHintText(Format(rsPreviewLoadErrorFmt, [ExtractFileName(AName)]));
      Exit;
    end;
  end;
  FHint.Visible := False;
  FIsText := True;
  if FImage <> nil then FImage.Visible := False;
  FreeAndNil(FImageSource);
  if FBar <> nil then
  begin
    FBar.Visible := True;
    SetBarMode(True);
  end;
  UpdateEditorVisibility;
  FEdit.Invalidate;
  if FWrapEdit <> nil then FWrapEdit.Invalidate;
end;

procedure TPreviewPane.ShowHintText(const AText: string);
begin
  if (FHint = nil) or (FEdit = nil) then Exit;
  FIsText := False;
  FEdit.Visible := False;
  if FWrapEdit <> nil then FWrapEdit.Visible := False;
  if FBar <> nil then FBar.Visible := False;
  if FImage <> nil then FImage.Visible := False;
  FHint.Caption := AText;
  FHint.Visible := True;
  FHint.Invalidate;
end;

procedure TPreviewPane.ClearText;
begin
  FRaw := nil;
  FName := '';
  FIsText := False;
  if FEdit <> nil then
  begin
    FEdit.Visible := False;
    FEdit.Highlighter := nil;
    if FHighlighter <> nil then FreeAndNil(FHighlighter);
    FEdit.Lines.Clear;
  end;
  if FWrapEdit <> nil then
  begin
    FWrapEdit.Visible := False;
    FWrapEdit.Highlighter := nil;
    FWrapEdit.Lines.Clear;
  end;
  if FHighlighter2 <> nil then FreeAndNil(FHighlighter2);
  if FBar <> nil then FBar.Visible := False;
end;

function TPreviewPane.IsTextInput(AControl: TControl): Boolean;
begin
  Result := (AControl = FEncCombo) or (AControl = FLangCombo) or
    (AControl = FEdit) or (AControl = FWrapEdit);
end;

procedure TPreviewPane.SetTextBarMode(AText: Boolean);
begin
  if FBar = nil then Exit;
  if FEncCombo <> nil then FEncCombo.Visible := AText;
  if FWrapBtn <> nil then FWrapBtn.Visible := AText;
  if FLangCombo <> nil then FLangCombo.Visible := AText;
end;

procedure TPreviewPane.UpdateEditorVisibility;
var
  Wrap: Boolean;
begin
  Wrap := (FWrapBtn <> nil) and FWrapBtn.Down;
  if FEdit <> nil then
    FEdit.Visible := FIsText and (not Wrap);
  if FWrapEdit <> nil then
    FWrapEdit.Visible := FIsText and Wrap;
end;

procedure TPreviewPane.ApplyThemePalette;
var
  St: TTyStyleSet;
  Bg, Ink, Gutter: TColor;
  Pal: TZPreviewPalette;
begin
  if FEdit = nil then Exit;
  St := TyDefaultController.Model.ResolveStyle('TyPanel', '', []);
  if St.Background.Kind = tfkNone then
    Bg := clWindow
  else
    Bg := TyColorToLCL(St.Background.Color);
  if tpTextColor in St.Present then
    Ink := TyColorToLCL(St.TextColor)
  else
    Ink := clWindowText;
  { The line-number strip is drawn from the chrome surface, the same colour as
    the pane furniture around the editor, so the two do not read as different
    greys side by side. }
  St := TyDefaultController.Model.ResolveStyle('TyStatusBar', '', []);
  if St.Background.Kind = tfkNone then
    Gutter := clNone
  else
    Gutter := TyColorToLCL(St.Background.Color);
  Pal := TzMakePreviewPalette(Bg, Ink, Gutter);
  TzPreviewStyleEditor(FEdit, Pal);
  if FWrapEdit <> nil then TzPreviewStyleEditor(FWrapEdit, Pal);
  if FHighlighter <> nil then
    TzPreviewTintHighlighter(FHighlighter, Pal);
  if FHighlighter2 <> nil then
    TzPreviewTintHighlighter(FHighlighter2, Pal);
end;

procedure TPreviewPane.SetHighlighter;
begin
  if FEdit = nil then Exit;
  if FHighlighter <> nil then
  begin
    FEdit.Highlighter := nil;
    FreeAndNil(FHighlighter);
  end;
  if FHighlighter2 <> nil then
  begin
    if FWrapEdit <> nil then FWrapEdit.Highlighter := nil;
    FreeAndNil(FHighlighter2);
  end;
  { FLanguage is the picker's current choice; PreviewLanguageNone builds no
    highlighter at all, which is what "None" (plain text) means. }
  FHighlighter := TzPreviewHighlighter(Self, FLanguage);
  FHighlighter2 := TzPreviewHighlighter(Self, FLanguage);
  if FHighlighter <> nil then
    FEdit.Highlighter := FHighlighter;
  if (FHighlighter2 <> nil) and (FWrapEdit <> nil) then
    FWrapEdit.Highlighter := FHighlighter2;
  ApplyThemePalette;
end;

procedure TPreviewPane.EncChange(Sender: TObject);
begin
  if FEncGuard or (FEncCombo = nil) then Exit;
  if (FEncCombo.ItemIndex < 0) or (FEncCombo.ItemIndex = FEncIndex) then Exit;
  FEncIndex := FEncCombo.ItemIndex;
  try
    RefreshText;
  except
    on E: Exception do
      ShowHintText(Format(rsPreviewLoadErrorFmt, [ExtractFileName(FName)]));
  end;
end;

procedure TPreviewPane.WrapClick(Sender: TObject);
var
  Src, Dst: TSynEdit;
  Row, TopRow: Integer;
begin
  if FWrapBtn = nil then Exit;
  Src := ActiveEditor;
  FWrapBtn.Down := not FWrapBtn.Down;
  Dst := ActiveEditor;
  { Switching viewers must not lose the reader's place. }
  if (Src <> nil) and (Dst <> nil) and (Src <> Dst) then
  begin
    Row := Src.CaretY;
    TopRow := Src.TopLine;
    UpdateEditorVisibility;
    Dst.CaretXY := Point(1, Row);
    Dst.TopLine := TopRow;
  end
  else
    UpdateEditorVisibility;
  if Dst <> nil then Dst.Invalidate;
end;

procedure TPreviewPane.LanguageChange(Sender: TObject);
begin
  { Ignore the programmatic write that shows the detected language. }
  if FLangGuard or (FLangCombo = nil) then Exit;
  if FLangCombo.ItemIndex < 0 then Exit;
  FLanguage := FLangCombo.ItemIndex;
  try
    SetHighlighter;
  except
    on E: Exception do
      ShowHintText(Format(rsPreviewLoadErrorFmt, [ExtractFileName(FName)]));
  end;
end;

procedure TPreviewPane.SelectLanguage(AIndex: Integer);
begin
  if FLangCombo = nil then Exit;
  FLangGuard := True;
  try
    if (AIndex < 0) or (AIndex >= FLangCombo.Items.Count) then AIndex := 0;
    FLangCombo.ItemIndex := AIndex;
  finally
    FLangGuard := False;
  end;
end;

end.
