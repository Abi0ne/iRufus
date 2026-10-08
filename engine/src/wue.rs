//! Windows User Experience options: generation of the Windows Setup answer
//! file, ported from Rufus' `CreateUnattendXml()` (wue.c).
//!
//! Placement differs from Rufus, which edits `sources/boot.wim` with wimlib:
//! - if any option needs the `windowsPE` pass, the whole answer file is written
//!   as `/Autounattend.xml` at the root of the media (Windows Setup's implicit
//!   answer-file search on removable media, which also caches it into
//!   `%WINDIR%\Panther` for the later passes);
//! - otherwise it goes to `/sources/$OEM$/$$/Panther/unattend.xml`, exactly
//!   like Rufus, so it is copied into the installed system.

use serde::Deserialize;

use crate::error::{EngineError, Result};

#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default)]
pub struct LocaleSettings {
    pub input_locale: String,
    pub system_locale: String,
    pub user_locale: String,
    pub ui_language: String,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default)]
pub struct WueOptions {
    /// `amd64`, `arm64` or `x86`.
    pub arch: String,
    /// Bypass Windows 11 TPM 2.0, Secure Boot and 4 GB RAM checks (LabConfig).
    pub bypass_requirements: bool,
    /// Allow setup without a Microsoft account (BypassNRO).
    pub no_online_account: bool,
    /// Create a local administrator account with this name (blank password,
    /// change forced at first logon).
    pub local_account: Option<String>,
    /// Answer the privacy questions with "no data collection".
    pub disable_data_collection: bool,
    /// Copy regional settings from this Mac.
    pub locale: Option<LocaleSettings>,
    /// Prevent automatic BitLocker device encryption.
    pub disable_bitlocker: bool,
}
// Not ported: Rufus' "offline internal drives" (SanPolicy) only applies to
// Windows To Go, and S Mode / CA 2023 / SkuSiPolicy / QoL / silent install
// need boot.wim servicing or Windows binaries (see docs/ANALISI.md).

pub const ROOT_ANSWER_FILE: &str = "/Autounattend.xml";
pub const OEM_ANSWER_FILE: &str = "/sources/$OEM$/$$/Panther/unattend.xml";

const UNALLOWED_ACCOUNT_NAMES: &[&str] = &[
    "Administrator",
    "Järjestelmänvalvoja",
    "Administrateur",
    "Rendszergazda",
    "Administrador",
    "Администратор",
    "Administratör",
    "Guest",
    "DefaultAccount",
    "WDAGUtilityAccount",
    "HelpAssistant",
    "KRBTGT",
    "Local",
    "NONE",
    "SYSTEM",
];
const USERNAME_INVALID_CHARS: &str = "/\\[]:|<>+=;,?*%\"@";
pub const MAX_USERNAME_LEN: usize = 20;

impl WueOptions {
    pub fn is_empty(&self) -> bool {
        !(self.bypass_requirements
            || self.no_online_account
            || self.local_account.is_some()
            || self.disable_data_collection
            || self.locale.is_some()
            || self.disable_bitlocker)
    }

    fn needs_windows_pe(&self) -> bool {
        self.bypass_requirements
    }

    /// Path of the answer file on the media.
    pub fn target_path(&self) -> &'static str {
        if self.needs_windows_pe() {
            ROOT_ANSWER_FILE
        } else {
            OEM_ANSWER_FILE
        }
    }
}

/// Validate and sanitise a local account name like Rufus does.
/// Returns the sanitised name, or an error if it is reserved or empty.
pub fn sanitize_account_name(name: &str) -> Result<String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err(EngineError::InvalidArgument(
            "the local account name is empty".into(),
        ));
    }
    if UNALLOWED_ACCOUNT_NAMES
        .iter()
        .any(|n| n.eq_ignore_ascii_case(trimmed) || n.to_lowercase() == trimmed.to_lowercase())
    {
        return Err(EngineError::InvalidArgument(format!(
            "'{trimmed}' is a reserved Windows account name"
        )));
    }
    let cleaned: String = trimmed
        .chars()
        .map(|c| {
            if USERNAME_INVALID_CHARS.contains(c) || c.is_control() {
                '_'
            } else {
                c
            }
        })
        .take(MAX_USERNAME_LEN)
        .collect();
    let cleaned = cleaned.trim_end_matches(['.', ' ']).to_string();
    if cleaned.is_empty() {
        return Err(EngineError::InvalidArgument(
            "the local account name is empty after sanitising".into(),
        ));
    }
    Ok(cleaned)
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn valid_locale(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 16
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == ':')
}

fn component(name: &str, arch: &str) -> String {
    format!(
        "    <component name=\"{name}\" processorArchitecture=\"{arch}\" language=\"neutral\" \
xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" \
publicKeyToken=\"31bf3856ad364e35\" versionScope=\"nonSxS\">\n"
    )
}

/// Build the answer file. Returns `None` when no option is selected.
pub fn build_unattend(opts: &WueOptions) -> Result<Option<String>> {
    if opts.is_empty() {
        return Ok(None);
    }
    let arch = match opts.arch.as_str() {
        a @ ("amd64" | "arm64" | "x86") => a,
        other => {
            return Err(EngineError::InvalidArgument(format!(
                "unsupported Windows architecture '{other}'"
            )));
        }
    };
    let account = opts
        .local_account
        .as_deref()
        .map(sanitize_account_name)
        .transpose()?;
    if let Some(l) = &opts.locale {
        for v in [
            &l.input_locale,
            &l.system_locale,
            &l.user_locale,
            &l.ui_language,
        ] {
            if !valid_locale(v) {
                return Err(EngineError::InvalidArgument(format!(
                    "invalid locale identifier '{v}'"
                )));
            }
        }
    }

    let mut x = String::new();
    x.push_str("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    x.push_str("<unattend xmlns=\"urn:schemas-microsoft-com:unattend\">\n");

    if opts.needs_windows_pe() {
        x.push_str("  <settings pass=\"windowsPE\">\n");
        x.push_str(&component("Microsoft-Windows-Setup", arch));
        x.push_str("      <UserData>\n        <AcceptEula>true</AcceptEula>\n        <ProductKey>\n          <Key />\n        </ProductKey>\n      </UserData>\n");
        x.push_str("      <RunSynchronous>\n");
        for (i, v) in ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck"]
            .iter()
            .enumerate()
        {
            x.push_str(&format!(
                "        <RunSynchronousCommand wcm:action=\"add\">\n          <Order>{}</Order>\n          <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v {v} /t REG_DWORD /d 1 /f</Path>\n        </RunSynchronousCommand>\n",
                i + 1
            ));
        }
        x.push_str("      </RunSynchronous>\n    </component>\n  </settings>\n");
    }

    if opts.no_online_account {
        x.push_str("  <settings pass=\"specialize\">\n");
        x.push_str(&component("Microsoft-Windows-Deployment", arch));
        x.push_str("      <RunSynchronous>\n        <RunSynchronousCommand wcm:action=\"add\">\n          <Order>1</Order>\n          <Path>reg add \"HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\OOBE\" /v BypassNRO /t REG_DWORD /d 1 /f</Path>\n        </RunSynchronousCommand>\n      </RunSynchronous>\n");
        x.push_str("    </component>\n  </settings>\n");
    }

    let shell_setup = opts.disable_data_collection || account.is_some();
    if shell_setup || opts.locale.is_some() || opts.disable_bitlocker {
        x.push_str("  <settings pass=\"oobeSystem\">\n");
        if shell_setup {
            x.push_str(&component("Microsoft-Windows-Shell-Setup", arch));
            if opts.disable_data_collection {
                x.push_str("      <OOBE>\n        <HideEULAPage>true</HideEULAPage>\n        <ProtectYourPC>3</ProtectYourPC>\n      </OOBE>\n");
            }
            if let Some(name) = &account {
                let n = xml_escape(name);
                x.push_str(&format!(
                    "      <UserAccounts>\n        <LocalAccounts>\n          <LocalAccount wcm:action=\"add\">\n            <Name>{n}</Name>\n            <DisplayName>{n}</DisplayName>\n            <Group>Administrators;Power Users</Group>\n            <Password>\n              <Value>UABhAHMAcwB3AG8AcgBkAA==</Value>\n              <PlainText>false</PlainText>\n            </Password>\n          </LocalAccount>\n        </LocalAccounts>\n      </UserAccounts>\n"
                ));
                let cmd_name = xml_escape(&name.replace('"', ""));
                x.push_str(&format!(
                    "      <FirstLogonCommands>\n        <SynchronousCommand wcm:action=\"add\">\n          <Order>1</Order>\n          <CommandLine>net user &quot;{cmd_name}&quot; /logonpasswordchg:yes</CommandLine>\n        </SynchronousCommand>\n        <SynchronousCommand wcm:action=\"add\">\n          <Order>2</Order>\n          <CommandLine>net accounts /maxpwage:unlimited</CommandLine>\n        </SynchronousCommand>\n      </FirstLogonCommands>\n"
                ));
            }
            x.push_str("    </component>\n");
        }
        if let Some(l) = &opts.locale {
            x.push_str(&component("Microsoft-Windows-International-Core", arch));
            x.push_str(&format!(
                "      <InputLocale>{}</InputLocale>\n      <SystemLocale>{}</SystemLocale>\n      <UserLocale>{}</UserLocale>\n      <UILanguage>{}</UILanguage>\n",
                l.input_locale, l.system_locale, l.user_locale, l.ui_language
            ));
            x.push_str("    </component>\n");
        }
        if opts.disable_bitlocker {
            x.push_str(&component(
                "Microsoft-Windows-SecureStartup-FilterDriver",
                arch,
            ));
            x.push_str(
                "      <PreventDeviceEncryption>true</PreventDeviceEncryption>\n    </component>\n",
            );
            x.push_str(&component("Microsoft-Windows-EnhancedStorage-Adm", arch));
            x.push_str("      <TCGSecurityActivationDisabled>1</TCGSecurityActivationDisabled>\n    </component>\n");
        }
        x.push_str("  </settings>\n");
    }

    x.push_str("</unattend>\n");
    Ok(Some(x))
}

/// Human-readable list of applied options for the log (no personal data).
pub fn describe(opts: &WueOptions) -> Vec<&'static str> {
    let mut v = Vec::new();
    if opts.bypass_requirements {
        v.push("bypass TPM/Secure Boot/RAM requirements");
    }
    if opts.no_online_account {
        v.push("allow setup without Microsoft account");
    }
    if opts.local_account.is_some() {
        v.push("create local account (name not logged)");
    }
    if opts.disable_data_collection {
        v.push("disable data collection prompts");
    }
    if opts.locale.is_some() {
        v.push("copy regional settings");
    }
    if opts.disable_bitlocker {
        v.push("disable automatic BitLocker");
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all() -> WueOptions {
        WueOptions {
            arch: "amd64".into(),
            bypass_requirements: true,
            no_online_account: true,
            local_account: Some("Mario & <Rossi>".into()),
            disable_data_collection: true,
            locale: Some(LocaleSettings {
                input_locale: "it-IT".into(),
                system_locale: "it-IT".into(),
                user_locale: "it-IT".into(),
                ui_language: "it-IT".into(),
            }),
            disable_bitlocker: true,
        }
    }

    fn well_formed(x: &str) -> bool {
        // Minimal structural check: every <tag> opened is closed in order.
        let mut stack: Vec<String> = Vec::new();
        let mut rest = x;
        while let Some(p) = rest.find('<') {
            let end = rest[p..].find('>').unwrap() + p;
            let tag = &rest[p + 1..end];
            rest = &rest[end + 1..];
            if tag.starts_with('?') || tag.ends_with('/') {
                continue;
            }
            if let Some(name) = tag.strip_prefix('/') {
                if stack.pop().as_deref() != Some(name) {
                    return false;
                }
            } else {
                stack.push(tag.split_whitespace().next().unwrap().to_string());
            }
        }
        stack.is_empty()
    }

    #[test]
    fn full_answer_file_is_well_formed_and_escaped() {
        let x = build_unattend(&all()).unwrap().unwrap();
        assert!(well_formed(&x), "{x}");
        assert!(x.contains("<Name>Mario &amp; _Rossi_</Name>"), "{x}");
        assert!(
            x.contains("BypassTPMCheck")
                && x.contains("BypassSecureBootCheck")
                && x.contains("BypassRAMCheck")
        );
        assert!(x.contains("BypassNRO"));
        assert!(x.contains("<ProtectYourPC>3</ProtectYourPC>"));
        assert!(!x.contains("SanPolicy"));
        assert!(x.contains("<UILanguage>it-IT</UILanguage>"));
        assert!(x.contains("processorArchitecture=\"amd64\""));
        assert_eq!(all().target_path(), ROOT_ANSWER_FILE);
    }

    #[test]
    fn options_without_windows_pe_go_to_oem_folder() {
        let o = WueOptions {
            arch: "arm64".into(),
            no_online_account: true,
            ..Default::default()
        };
        let x = build_unattend(&o).unwrap().unwrap();
        assert!(!x.contains("windowsPE"));
        assert!(well_formed(&x));
        assert_eq!(o.target_path(), OEM_ANSWER_FILE);
    }

    #[test]
    fn empty_options_produce_nothing() {
        assert!(
            build_unattend(&WueOptions {
                arch: "amd64".into(),
                ..Default::default()
            })
            .unwrap()
            .is_none()
        );
    }

    #[test]
    fn account_names_are_validated() {
        assert!(sanitize_account_name("administrator").is_err());
        assert!(sanitize_account_name("   ").is_err());
        assert_eq!(sanitize_account_name(" user:name ").unwrap(), "user_name");
        assert_eq!(
            sanitize_account_name("abcdefghijklmnopqrstuvwxyz")
                .unwrap()
                .len(),
            20
        );
        assert!(
            build_unattend(&WueOptions {
                arch: "amd64".into(),
                local_account: Some("Guest".into()),
                ..Default::default()
            })
            .is_err()
        );
    }

    #[test]
    fn bad_arch_and_locale_are_rejected() {
        assert!(
            build_unattend(&WueOptions {
                arch: "ia64".into(),
                no_online_account: true,
                ..Default::default()
            })
            .is_err()
        );
        let o = WueOptions {
            arch: "amd64".into(),
            locale: Some(LocaleSettings {
                input_locale: "<x>".into(),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(build_unattend(&o).is_err());
    }
}
