{
	--- TYPES AND VARIABLES ---
}
type
	TProduct = record
		File: String;
		Title: String;
		Parameters: String;
		ForceSuccess: Boolean;
		InstallClean: Boolean;
		MustRebootAfter: Boolean;
	end;

	InstallResult = (InstallSuccessful, InstallRebootRequired, InstallError);

var
	installMemo, downloadMemo: String;
	products: array of TProduct;
	delayedReboot, isForcedX86: Boolean;
	DownloadPage: TDownloadWizardPage;

procedure initproducts();
begin
	DownloadPage := CreateDownloadPage(CustomMessage('depinstall_title'), CustomMessage('depinstall_description'), nil);
end;

procedure AddProduct(filename, parameters, title, size, url: String; forceSuccess, installClean, mustRebootAfter: Boolean);
{
	Adds a product to the list of products to download.
	Parameters:
		filename: the file name under which to save the file
		parameters: the parameters with which to run the file
		title: the product title
		size: the file size
		url: the URL to download from
		forceSuccess: whether to continue in case of setup failure
		installClean: whether the product needs a reboot before installing
		mustRebootAfter: whether the product needs a reboot after installing
}
var
	path: String;
	i: Integer;
begin
	path := ExpandConstant('{src}{\}') + CustomMessage('DependenciesDir') + '\' + filename;
	if not FileExists(path) then begin
		path := ExpandConstant('{tmp}{\}') + filename;

		if not FileExists(path) then begin
			DownloadPage.Add(url, filename, '');

			downloadMemo := downloadMemo + '%1' + title + ' (' + size + ')' + #13;
		end else begin
			installMemo := installMemo + '%1' + title + #13;
		end;
	end else begin
		installMemo := installMemo + '%1' + title + #13;
	end;

	i := GetArrayLength(products);
	SetArrayLength(products, i + 1);
	products[i].File := path;
	products[i].Title := title;
	products[i].Parameters := parameters;
	products[i].ForceSuccess := forceSuccess;
	products[i].InstallClean := installClean;
	products[i].MustRebootAfter := mustRebootAfter;
end;

function PendingReboot: Boolean;
{
	Checks whether the machine has a pending reboot.
}
var
	names: String;
begin
	if (RegQueryMultiStringValue(HKEY_LOCAL_MACHINE, 'SYSTEM\CurrentControlSet\Control\Session Manager', 'PendingFileRenameOperations', names)) then begin
		Result := true;
	end else if ((RegQueryMultiStringValue(HKEY_LOCAL_MACHINE, 'SYSTEM\CurrentControlSet\Control\Session Manager', 'SetupExecute', names)) and (names <> ''))  then begin
		Result := true;
	end else begin
		Result := false;
	end;
end;

function InstallProducts: InstallResult;
{
	Installs the downloaded products
}
var
	resultCode, i, productCount, finishCount: Integer;
begin
	Result := InstallSuccessful;
	productCount := GetArrayLength(products);

	if productCount > 0 then begin
		for i := 0 to productCount - 1 do begin
			if (products[i].InstallClean and (delayedReboot or PendingReboot())) then begin
				Result := InstallRebootRequired;
				break;
			end;

			DownloadPage.Show;
			DownloadPage.SetText(FmtMessage(CustomMessage('depinstall_status'), [products[i].Title]), '');
			DownloadPage.SetProgress(i + 1, productCount);

			while true do begin
				// set 0 as used code for shown error if ShellExec fails
				resultCode := 0;
				if ShellExec('', products[i].File, products[i].Parameters, '', SW_SHOWNORMAL, ewWaitUntilTerminated, resultCode) then begin
					// setup executed; resultCode contains the exit code
					if (products[i].MustRebootAfter) then begin
						// delay reboot after install if we installed the last dependency anyways
						if (i = productCount - 1) then begin
							delayedReboot := true;
						end else begin
							Result := InstallRebootRequired;
						end;
						break;
					end else if (resultCode = 0) or (products[i].ForceSuccess) then begin
						finishCount := finishCount + 1;
						break;
					end else if (resultCode = 3010) then begin
						// Windows Installer resultCode 3010: ERROR_SUCCESS_REBOOT_REQUIRED
						delayedReboot := true;
						finishCount := finishCount + 1;
						break;
					end;
				end;

				case SuppressibleMsgBox(FmtMessage(SetupMessage(msgErrorFunctionFailed), [products[i].Title, IntToStr(resultCode)]), mbError, MB_ABORTRETRYIGNORE, IDIGNORE) of
					IDABORT: begin
						Result := InstallError;
						break;
					end;
					IDIGNORE: begin
						break;
					end;
				end;
			end;

			if Result <> InstallSuccessful then begin
				break;
			end;
		end;

		// only leave not installed products for error message
		for i := 0 to productCount - finishCount - 1 do begin
			products[i] := products[i+finishCount];
		end;
		SetArrayLength(products, productCount - finishCount);

		DownloadPage.Hide;
	end;
end;

{
	--------------------
	INNO EVENT FUNCTIONS
	--------------------
}

function PrepareToInstall(var NeedsRestart: Boolean): String;
{
	Before the "preparing to install" page.
	See: https://www.jrsoftware.org/ishelp/index.php?topic=scriptevents
}
var
	i: Integer;
	s: String;
begin
	delayedReboot := false;

	case InstallProducts() of
		InstallError: begin
			s := CustomMessage('depinstall_error');

			for i := 0 to GetArrayLength(products) - 1 do begin
				s := s + #13 + '	' + products[i].Title;
			end;

			Result := s;
		end;
		InstallRebootRequired: begin
			Result := products[0].Title;
			NeedsRestart := true;

			// write into the registry that the installer needs to be executed again after restart
			RegWriteStringValue(HKEY_CURRENT_USER, 'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', 'InstallBootstrap', ExpandConstant('{srcexe}'));
		end;
	end;
end;

function NeedRestart: Boolean;
{
	Checks whether a restart is needed at the end of install
	See: https://www.jrsoftware.org/ishelp/index.php?topic=scriptevents
}
begin
	Result := delayedReboot;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
{
	Just before the "ready" page.
	See: https://www.jrsoftware.org/ishelp/index.php?topic=scriptevents
}
var
	s: String;
begin
	if downloadMemo <> '' then
		s := s + CustomMessage('depdownload_memo_title') + ':' + NewLine + FmtMessage(downloadMemo, [Space]) + NewLine;
	if installMemo <> '' then
		s := s + CustomMessage('depinstall_memo_title') + ':' + NewLine + FmtMessage(installMemo, [Space]) + NewLine;

	if MemoDirInfo <> '' then
		s := s + MemoDirInfo + NewLine + NewLine;
	if MemoGroupInfo <> '' then
		s := s + MemoGroupInfo + NewLine + NewLine;
	if MemoTasksInfo <> '' then
		s := s + MemoTasksInfo;

	Result := s
end;

function NextButtonClick(CurPageID: Integer): Boolean;
{
	At each "next" button click
	See: https://www.jrsoftware.org/ishelp/index.php?topic=scriptevents
}
var
	retry: Boolean;
begin
	Result := true;

	if (CurPageID = wpReady) and (downloadMemo <> '') then begin
		DownloadPage.Show;
		retry := true;
		while retry do begin
			retry := false;
			try
				DownloadPage.Download;
			except
				case SuppressibleMsgBox(AddPeriod(GetExceptionMessage), mbError, MB_ABORTRETRYIGNORE, IDIGNORE) of
					IDABORT: begin
						Result := false;
					end;
					IDRETRY: begin
						retry := true;
					end;
				end;
			end;
		end;
		DownloadPage.Hide;
	end;
end;

{
	-----------------------------
	ARCHITECTURE HELPER FUNCTIONS
	-----------------------------
}

function IsX86: Boolean;
{
	Gets whether the computer is x86 (32 bits).
}
begin
	Result := isForcedX86 or (ProcessorArchitecture = paX86) or (ProcessorArchitecture = paUnknown);
end;

function IsX64: Boolean;
{
	Gets whether the computer is x64 (64 bits).
}
begin
	Result := (not isForcedX86) and Is64BitInstallMode and (ProcessorArchitecture = paX64);
end;

function IsIA64: Boolean;
{
	Gets whether the computer is IA64 (Itanium 64 bits).
}
begin
	Result := (not isForcedX86) and Is64BitInstallMode and (ProcessorArchitecture = paIA64);
end;

function GetString(x86, x64, ia64: String): String;
{
	Gets a string depending on the computer architecture.
	Parameters:
		x86: the string if the computer is x86
		x64: the string if the computer is x64
		ia64: the string if the computer is IA64
}
begin
	if IsX64() and (x64 <> '') then begin
		Result := x64;
	end else if IsIA64() and (ia64 <> '') then begin
		Result := ia64;
	end else begin
		Result := x86;
	end;
end;

function GetArchitectureString(): String;
{
	Gets the "standard" architecture suffix string.
	Returns either _x64, _ia64 or nothing.
}
begin
	if IsX64() then begin
		Result := '_x64';
	end else if IsIA64() then begin
		Result := '_ia64';
	end else begin
		Result := '';
	end;
end;

procedure SetForceX86(value: Boolean);
{
	Forces the setup to use X86 products
}
begin
	isForcedX86 := value;
end;
