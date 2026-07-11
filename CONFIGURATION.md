# Configuration notes

This document covers the non-obvious parts of the setup. Standard Postfix, TLS, and SASL configuration is not repeated here.

---

## Exchange Online App RBAC

This relay uses the newer App RBAC model, not the legacy `SMTP.SendAsApp` Entra API permission.

**Do not add `SMTP.SendAsApp` as an Entra API application permission.** If it is present, remove it and obtain a fresh token — the token must not contain `SMTP.SendAsApp` in the `roles` claim.

Permission is granted exclusively through Exchange Online PowerShell:

```powershell
# Register the service principal in Exchange Online
New-ServicePrincipal `
  -AppId "<APPLICATION-CLIENT-ID>" `
  -ObjectId "<ENTERPRISE-APPLICATION-OBJECT-ID>" `
  -DisplayName "Postfix SMTP Relay"

# Create a mail-enabled security group for permitted mailboxes
New-DistributionGroup `
  -Name "Postfix SMTP Relay Mailboxes" `
  -Alias "postfix-smtp-relay" `
  -Type Security

Add-DistributionGroupMember `
  -Identity "Postfix SMTP Relay Mailboxes" `
  -Member "smtp@example.com"

# Create a management scope scoped to that group
$group = Get-DistributionGroup "Postfix SMTP Relay Mailboxes"
New-ManagementScope `
  -Name "Postfix SMTP Relay Scope" `
  -RecipientRestrictionFilter "MemberOfGroup -eq '$($group.DistinguishedName)'"

# Assign the SMTP application role
New-ManagementRoleAssignment `
  -Name "Postfix SMTP SendAsApp" `
  -Role "Application SMTP.SendAsApp" `
  -App "<APPLICATION-CLIENT-ID>" `
  -CustomResourceScope "Postfix SMTP Relay Scope"
```

Verify:

```powershell
Test-ServicePrincipalAuthorization `
  -Identity "<APPLICATION-CLIENT-ID>" `
  -Resource "smtp@example.com"
# InScope must be True
```

App RBAC changes can take 30–60 minutes to propagate.

---

## Token endpoint and scope

```text
https://login.microsoftonline.com/<TENANT-ID>/oauth2/v2.0/token
scope: https://outlook.office365.com/.default
grant_type: client_credentials
```

No refresh token is issued. The daemon requests a new access token before the current one expires.

---

## sasl-xoauth2 plugin — app-only limitation

The plugin expects a `refresh_token` field in the token file even when using app-only OAuth. Since `client_credentials` does not issue a refresh token, use a placeholder:

```json
{
  "access_token": "...",
  "expiry": 1783789000,
  "user": "smtp@example.com",
  "refresh_token": "NA"
}
```

The daemon always writes a fresh token before expiry so the plugin never attempts to use `NA`.

---

## Postfix — outbound smtp transport chroot

On Ubuntu 24.04 LTS the outbound smtp unix transport runs in a chroot by default. The token files are outside the chroot and will not be found.

Check current state:

```bash
postconf -M smtp/unix
```

If the fifth column is `y`, change it to `n` in `/etc/postfix/master.cf`:

```text
smtp      unix  -       -       n       -       -       smtp
```

Then restart Postfix. Without this change the plugin reports `TokenStore::Read: failed to open file` even though the file exists on the host.

---

## systemd unit — StartLimit placement

`StartLimitIntervalSec` and `StartLimitBurst` belong in the `[Unit]` section, not `[Service]`. Placing them in `[Service]` produces a warning and they are silently ignored.

```ini
[Unit]
Description=Postfix OAuth2 token daemon
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
...
Restart=on-failure
RestartSec=10
```

---

## References

- [Exchange Online App RBAC](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac)
- [SMTP App RBAC onboarding](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/smtp-app-rbac-onboarding)
- [sasl-xoauth2](https://github.com/tarickb/sasl-xoauth2)
