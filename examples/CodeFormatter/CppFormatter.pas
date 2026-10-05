unit CppFormatter;

interface

implementation

{ $DEFINE FORMAT_TESTING}

uses
  System.SysUtils, FormatMgr, ToolsApi, IDEIntf, EnvOptions, VEdOpts,
  EdKrnl, CppAddInFormatter, EditorBuffer, DesignIntf, CppMgr, CodeMgr,
  System.Generics.Collections, System.Generics.Defaults, Winapi.Windows,
  System.IOUtils, AppStrs;

const
  cLibClangFormatDll = 'compclangformat.dll';

resourcestring
  sGroup = 'Formatter';

  sDialogMessage = '''
    (You can restore this dialog box from the Tools, Options dialog.
    Under Languages, C++, Formatting.)
    ''';

type
  TPosIndex = record
    Pos: Integer;
    Index: Integer;
  end;

  TCppFormatter = class(TInterfacedObject, IOTACodeFormatter)
  private
    FModule: THandle;
    FLoaded: Boolean;
    InitFormatter: procedure; cdecl;
    ClangFormat: function (FileName, Source: PAnsiChar; SourceLength, Offset, Length: Cardinal;
      var CursorOffset: Cardinal; Style, Fallback: PAnsiChar; var OutData: PAnsiChar;
      var outDataLength: Integer): Cardinal; cdecl;
    UpdatePos: procedure (ACount: Cardinal; AList: array of Cardinal); cdecl;
    ReleaseFormatter: procedure cdecl;
    GetFormatErrors: function: PAnsiChar; cdecl;

    function InitFormatterCalls: Boolean;
    procedure SaveConfirmDlg;

    { IOTACodeFormatter }
    function HandleFile(const AFileName: string): Boolean;
    function FormatLine(const AModule: IOTAModule; const AEditorContent: IOTAEditorContent;
      const AContent: UTF8String; ASelectedOffset, ASelectedLen: Integer;
      var ACursorOffset: Integer; var AFormattedText: UTF8String): Boolean;
    function CanFormatLine(const AModule: IOTAModule; const AEdPos: TOTAEditPos;
      ANumLines: Integer): Boolean;
    function CanFormatOnSave: Boolean;
    function FormatSelected(const AModule: IOTAModule; const AContent: UTF8string;
      ASelectedOffset, ASelectedLen: Integer; var ACursorOffset: Integer;
      var AFormattedText: UTF8String): Boolean;
    function FormatFile(const AModule: IOTAModule; const AContent: UTF8String;
      var ACursorOffset: Integer; var AFormattedText: UTF8String): Boolean;

    function GetConfirmDlg: Boolean;
    procedure SetConfirmDlg(AValue: Boolean);
    function GetConfirmDlgHintText: string;
    function SupportsOffsetRemapping: Boolean;
  protected
    function FormatUsingClang(const AFileName: string; const AContent: UTF8String;
      const AStyle: string; ASelectedOffset, ASelectedLen: Integer;
      var ACursorOffset: Integer; var AFormatted: UTF8String): Boolean;
    function DoFormat(const AFileName: string; const LContent: UTF8String; ASelectedOffset, ASelectedLen: Integer;
      var ACursorOffset: Integer; var AResultText: UTF8String): Boolean;
    function GetEditBuffer(const AEditorContent: IOTAEditorContent): TEditBuffer;
  public
    constructor Create;
  end;

  TProductStartup = class
    class procedure PostCreate(Sender: TObject);
  end;


{ TCppFormatter }

constructor TCppFormatter.Create;
begin
  inherited;
  FLoaded := False;
end;


function TCppFormatter.CanFormatLine(const AModule: IOTAModule;
  const AEdPos: TOTAEditPos; ANumLines: Integer): Boolean;
begin
  Result := CppAddInFormatterOptions.CppFormatterAutoFormat.Value = 2; // need to add a const
  if Result and (CppAddInFormatterOptions.CppFormatterLineLimit.Value <> 0) then
    Result := ANumLines <= CppAddInFormatterOptions.CppFormatterLineLimit.Value;
end;

function TCppFormatter.CanFormatOnSave: Boolean;
begin
  Result := CppAddInFormatterOptions.CppFormatterAutoFormat.Value = 1; // need to add a const
end;

var
  Loaded: Boolean = False;

function TCppFormatter.FormatUsingClang(const AFileName: string;
  const AContent: UTF8String; const AStyle: string;
  ASelectedOffset, ASelectedLen: Integer; var ACursorOffset: Integer;
  var AFormatted: UTF8String): Boolean;
var
  LLen: Integer;
  LOut: PAnsiChar;
  LCount: Cardinal;
  LError: PAnsiChar;
  LGroup: IOTAMessageGroup;
  LRef: Pointer;
begin
  if not InitFormatterCalls then
    Exit(False);
  if not Loaded then
  begin
    InitFormatter;
    Loaded := True;
  end;

  Result := ClangFormat(PAnsiChar(UTF8Encode(AFileName)), PAnsiChar(AContent),
    Length(AContent), ASelectedOffset, ASelectedLen, Cardinal(ACursorOffset),
    'file', PAnsiChar(UTF8Encode(AStyle)), LOut, LLen) = 0;
  if Result then
  begin
    SetLength(AFormatted, LLen);
    System.Move(LOut^, PAnsiChar(AFormatted)^, LLen);

    var LOffsets := CodeFormatterServices.GetStoredOffsetsForFormatter(Self);
    LCount := Length(LOffsets);
    if LCount > 0 then
      UpdatePos(LCount, LOffsets);
    CodeFormatterServices.SetStoredOffsetsForFormatter(Self, LOffsets);
  end
  else
  begin
    LError := GetFormatErrors;
    if Assigned(LError) then
    begin
      LGroup := (BorlandIDEServices as IOTAMessageServices).AddMessageGroup(sGroup);
      (BorlandIDEServices as IOTAMessageServices).AddToolMessage('', IntToStr(GetTickCount) + ':' + UTF8ToString(LError), 'C++', 0, 0, nil, LRef, LGroup);
      (BorlandIDEServices as IOTAMessageServices).ShowMessageView(LGroup);
    end;
  end;

  ReleaseFormatter;
end;

{$IFDEF FORMAT_TESTING}
var TestFormatStyle: Integer;
{$ENDIF FORMAT_TESTING}

function TCppFormatter.DoFormat(const AFileName: string; const LContent: UTF8String;
  ASelectedOffset, ASelectedLen: Integer; var ACursorOffset: Integer;
  var AResultText: UTF8String): Boolean;

{$IFDEF FORMAT_TESTING}
  function MessWithResult(S: UTF8String): UTF8String;
  var
    Temp: string;
    LCRLF: string;
  begin
    LCRLF := #13#10;
    Temp := UTF8ToString(S);
    case TestFormatStyle of
      // Add Lines
      1: Result := UTF8Encode(System.SysUtils.StringReplace(Temp, LCRLF, LCRLF + LCRLF, [rfReplaceAll]));
      //Delete Lines
      2: Result := UTF8Encode(System.SysUtils.StringReplace(Temp, LCRLF + LCRLF, LCRLF, [rfReplaceAll]));
      //Add Spaces
      3: Result := UTF8Encode(System.SysUtils.StringReplace(Temp, ' ', '  ', [rfReplaceAll]));
      // Delete Spaces
      4: Result := UTF8Encode(System.SysUtils.StringReplace(Temp, '  ', ' ', [rfReplaceAll]));
      else
        Result := UTF8Encode(Temp);
    end
  end;
{$ENDIF FORMAT_TESTING}
var
  LStyle: string;
begin
{$IFDEF FORMAT_TESTING}
  Result := True;
//  if Length(ASelText) > 0 then
//    AResultText := MessWithResult(ASelText)
//  else
    AResultText := MessWithResult(LContent);
{$ELSE}

  LStyle := CppAddInFormatterOptions.CppFormatterFormatString.Value;

  Result := FormatUsingClang(AFileName, LContent, LStyle, ASelectedOffset, ASelectedLen,
    ACursorOffset, AResultText);
{$ENDIF FORMAT_TESTING}
end;

function TCppFormatter.FormatFile(const AModule: IOTAModule;
  const AContent: UTF8String; var ACursorOffset: Integer;
  var AFormattedText: UTF8String): Boolean;
var
  LFileName: string;
begin

{$IFDEF FORMAT_TESTING}
  if ExtractFileName(AModule.FileName).StartsWith('AL') then
    TestFormatStyle := 1
  else if ExtractFileName(AModule.FileName).StartsWith('DL') then
    TestFormatStyle := 2
  else if ExtractFileName(AModule.FileName).StartsWith('AS') then
    TestFormatStyle := 3
  else if ExtractFileName(AModule.FileName).StartsWith('DS') then
    TestFormatStyle := 4
  else
    TestFormatStyle := 0;
{$ENDIF FORMAT_TESTING}
  if Assigned(AModule) then
    LFileName := Amodule.FileName
  else
    LFileName := '';

  Result := DoFormat(LFileName, AContent, 0, Length(AContent) - 1, ACursorOffset, AFormattedText);
end;

function TCppFormatter.FormatLine(const AModule: IOTAModule; const AEditorContent: IOTAEditorContent;
      const AContent: UTF8String; ASelectedOffset, ASelectedLen: Integer;
      var ACursorOffset: Integer; var AFormattedText: UTF8String): Boolean;
var
  LFileName: string;
begin
  if Assigned(AModule) then
    LFileName := Amodule.FileName
  else
    LFileName := '';

  Result :=  DoFormat(LFileName, AContent, ASelectedOffset, ASelectedLen, ACursorOffset, AFormattedText);
end;

function TCppFormatter.FormatSelected(const AModule: IOTAModule;
  const AContent: UTF8string; ASelectedOffset, ASelectedLen: Integer;
  var ACursorOffset: Integer; var AFormattedText: UTF8String): Boolean;
var
  LFileName: string;
begin
  if Assigned(AModule) then
    LFileName := Amodule.FileName
  else
    LFileName := '';

  Result := DoFormat(LFileName, AContent, ASelectedOffset, ASelectedLen, ACursorOffset,
    AFormattedText);
end;

function TCppFormatter.GetConfirmDlg: Boolean;
begin
  Result := CppAddInFormatterOptions.CppFormatterConfirmationDialog.Value;
end;

function TCppFormatter.GetEditBuffer(
  const AEditorContent: IOTAEditorContent): TEditBuffer;
var
  LEditBuffer: IOTAEditBuffer;
  LImpl: IImplementation;
begin
  if Supports(AEditorContent, IOTAEditBuffer, LEditBuffer) then
  begin
    if Supports(LEditbuffer.GetTopView, IImplementation, LImpl) then
      Exit(TEditView(LImpl.GetInstance).EditBuffer);
  end;
  Result := nil;
end;

function TCppFormatter.HandleFile(const AFileName: string): Boolean;
begin
  Result := VEdOpts.MatchExtensions(AFileName,
    EnvironmentOptions.GetExtensionsForTypeID(cDefEdC));
end;

function TCppFormatter.InitFormatterCalls: Boolean;
begin
  if FLoaded then
    Exit(True);
  FModule := LoadLibrary(cLibClangFormatDll);
  if FModule <> 0 then
  begin
    InitFormatter := GetProcAddress(FModule, 'LibClangFormat_Init');
    ClangFormat := GetProcAddress(FModule, 'LibClangFormat');
    UpdatePos := GetProcAddress(FModule, 'LibClangFormat_UpdatePos');
    ReleaseFormatter := GetProcAddress(FModule, 'LibClangFormat_Release');
    GetFormatErrors := GetProcAddress(FModule, 'LibClangFormat_GetErrs');
    FLoaded := True;
  end;
  Result := FLoaded;
end;

procedure TCppFormatter.SaveConfirmDlg;
begin
  CppAddInFormatterOptions.SaveOptions;
end;

function TCppFormatter.GetConfirmDlgHintText: string;
begin
  Result := sDialogMessage;
end;

procedure TCppFormatter.SetConfirmDlg(AValue: Boolean);
begin
  CppAddInFormatterOptions.CppFormatterConfirmationDialog.Value := AValue;
  SaveConfirmDlg;
end;

function TCppFormatter.SupportsOffsetRemapping: Boolean;
begin
  Result := True;
end;

{ TProductStartup }

class procedure TProductStartup.PostCreate(Sender: TObject);
begin
  CodeFormatterServices.AddFormatter(TCppFormatter.Create);
end;

initialization
  IDEIntf.MainFormCreated.Add(TProductStartup.PostCreate);

end.
