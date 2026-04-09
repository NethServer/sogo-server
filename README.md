# [SOGo](https://sogo.nu/) container image based on Debian Trixie

Built with [buildah](https://buildah.io/) using a multi-stage approach:
- **Builder** stage: `debian:trixie` — compiles libwbxml, SOPE and SOGo into `/staging`
- **Runtime** stage: `debian:trixie-slim` — only compiled artefacts + runtime dependencies

Image published to: `ghcr.io/nethserver/sogo-server`

---

### Build

```sh
bash build-images.sh
```

---

### Run with Podman

The HTTP service listens on port **20001** (Apache reverse-proxying SOGo on port 20000).

Minimal example:

```sh
podman run -d --name sogo --restart always \
    --publish 127.0.0.1:20001:20001 \
    -v ./sogo.conf:/etc/sogo/sogo.conf:Z \
    ghcr.io/nethserver/sogo-server:latest
```

Full example with all bind mounts:

```sh
podman run -d --name sogo --restart always \
    --publish 127.0.0.1:20001:20001 \
    -v ./sogo.conf:/etc/sogo/sogo.conf:Z \
    -v ./SOGo.conf:/etc/apache2/conf-available/SOGo.conf:Z \
    -v ./cron-sogo:/etc/cron.d/sogo:Z \
    -v sogo-data:/var/lib/sogo:Z \
    -v sogo-spool:/var/spool/sogo:Z \
    -v sogo-logs:/var/log/sogo:Z \
    ghcr.io/nethserver/sogo-server:latest
```

---

### Configuration files

#### `/etc/sogo/sogo.conf`

```
{
  /* *********************  Main SOGo configuration file  **********************
   *                                                                           *
   * Since the content of this file is a dictionary in OpenStep plist format,  *
   * the curly braces enclosing the body of the configuration are mandatory.   *
   * See the Installation Guide for details on the format.                     *
   *                                                                           *
   * C and C++ style comments are supported.                                   *
   *                                                                           *
   * This example configuration contains only a subset of all available        *
   * configuration parameters. Please see the installation guide more details. *
   *                                                                           *
   * ~sogo/GNUstep/Defaults/.GNUstepDefaults has precedence over this file,    *
   * make sure to move it away to avoid unwanted parameter overrides.          *
   *                                                                           *
   * **************************************************************************/

  /* Database configuration (mysql://, postgresql:// or oracle://) */
  //SOGoProfileURL = "postgresql://sogo:sogo@localhost:5432/sogo/sogo_user_profile";
  //OCSFolderInfoURL = "postgresql://sogo:sogo@localhost:5432/sogo/sogo_folder_info";
  //OCSSessionsFolderURL = "postgresql://sogo:sogo@localhost:5432/sogo/sogo_sessions_folder";

  /* Mail */
  //SOGoDraftsFolderName = Drafts;
  //SOGoSentFolderName = Sent;
  //SOGoTrashFolderName = Trash;
  //SOGoJunkFolderName = Junk;
  //SOGoIMAPServer = "localhost";
  //SOGoSieveServer = "sieve://127.0.0.1:4190";
  //SOGoSMTPServer = "smtp://127.0.0.1";
  //SOGoMailDomain = acme.com;
  //SOGoMailingMechanism = smtp;
  //SOGoForceExternalLoginWithEmail = NO;
  //SOGoMailSpoolPath = /var/spool/sogo;
  //NGImap4AuthMechanism = "plain";
  //NGImap4ConnectionStringSeparator = "/";

  /* Notifications */
  //SOGoAppointmentSendEMailNotifications = NO;
  //SOGoACLsSendEMailNotifications = NO;
  //SOGoFoldersSendEMailNotifications = NO;

  /* Authentication */
  //SOGoPasswordChangeEnabled = YES;

  /* LDAP authentication example */
  //SOGoUserSources = (
  //  {
  //    type = ldap;
  //    CNFieldName = cn;
  //    UIDFieldName = uid;
  //    IDFieldName = uid; // first field of the DN for direct binds
  //    bindFields = (uid, mail); // array of fields to use for indirect binds
  //    baseDN = "ou=users,dc=acme,dc=com";
  //    bindDN = "uid=sogo,ou=users,dc=acme,dc=com";
  //    bindPassword = qwerty;
  //    canAuthenticate = YES;
  //    displayName = "Shared Addresses";
  //    hostname = "ldap://127.0.0.1:389";
  //    id = public;
  //    isAddressBook = YES;
  //  }
  //);

  /* LDAP AD/Samba4 example */
  //SOGoUserSources = (
  //  {
  //    type = ldap;
  //    CNFieldName = cn;
  //    UIDFieldName = sAMAccountName;
  //    baseDN = "CN=users,dc=domain,dc=tld";
  //    bindDN = "CN=sogo,CN=users,DC=domain,DC=tld";
  //    bindFields = (sAMAccountName, mail);
  //    bindPassword = password;
  //    canAuthenticate = YES;
  //    displayName = "Public";
  //    hostname = "ldap://127.0.0.1:389";
  //    filter = "mail = '*'";
  //    id = directory;
  //    isAddressBook = YES;
  //  }
  //);

  /* SQL authentication example */
  /*  These database columns MUST be present in the view/table:
   *    c_uid - will be used for authentication -  it's the username or username@domain.tld)
   *    c_name - which can be identical to c_uid -  will be used to uniquely identify entries
   *    c_password - password of the user, plain-text, md5 or sha encoded for now
   *    c_cn - the user's common name - such as "John Doe"
   *    mail - the user's mail address
   *  See the installation guide for more details
   */
  //SOGoUserSources =
  //  (
  //    {
  //      type = sql;
  //      id = directory;
  //      viewURL = "postgresql://sogo:sogo@127.0.0.1:5432/sogo/sogo_view";
  //      canAuthenticate = YES;
  //      isAddressBook = YES;
  //      userPasswordAlgorithm = md5;
  //    }
  //  );

  /* Web Interface */
  //SOGoPageTitle = SOGo;
  //SOGoVacationEnabled = YES;
  //SOGoForwardEnabled = YES;
  //SOGoSieveScriptsEnabled = YES;
  //SOGoMailAuxiliaryUserAccountsEnabled = YES;
  //SOGoTrustProxyAuthentication = NO;
  //SOGoXSRFValidationEnabled = NO;

  /* General - SOGoTimeZone *MUST* be defined */
  //SOGoLanguage = English;
  //SOGoTimeZone = America/Montreal;
  //SOGoCalendarDefaultRoles = (
  //  PublicDAndTViewer,
  //  ConfidentialDAndTViewer
  //);
  //SOGoSuperUsernames = (sogo1, sogo2); // This is an array - keep the parens!
  //SxVMemLimit = 384;
  //WOPidFile = "/var/run/sogo/sogo.pid";
  //SOGoMemcachedHost = "/var/run/memcached.sock";

  /* Debug */
  //SOGoDebugRequests = YES;
  //SoDebugBaseURL = YES;
  //ImapDebugEnabled = YES;
  //LDAPDebugEnabled = YES;
  //PGDebugEnabled = YES;
  //MySQL4DebugEnabled = YES;
  //SOGoUIxDebugEnabled = YES;
  //WODontZipResponse = YES;
  //WOLogFile = /var/log/sogo/sogo.log;
}
```

---

#### `/etc/apache2/conf-available/SOGo.conf`

Generated at build time from upstream SOGo source with paths adjusted for Debian
(`/usr/local/lib/GNUstep/SOGo/`). Mount your own only if you need to customize it.

```apache
Alias /SOGo.woa/WebServerResources/ \
      /usr/local/lib/GNUstep/SOGo/WebServerResources/
Alias /SOGo/WebServerResources/ \
      /usr/local/lib/GNUstep/SOGo/WebServerResources/

<Directory /usr/local/lib/GNUstep/SOGo/>
    AllowOverride None

    <IfVersion >= 2.4>
        Require all granted
    </IfVersion>

    <IfModule expires_module>
      ExpiresActive On
      ExpiresDefault "access plus 1 year"
    </IfModule>
</Directory>

Header always set Referrer-Policy "same-origin"

<Location /SOGo>
  Header set Cache-Control "max-age=0, no-cache, no-store"
</Location>

ProxyRequests Off
ProxyPreserveHost On
SetEnv proxy-nokeepalive 1

ProxyPass /SOGo http://127.0.0.1:20000/SOGo retry=0 nocanon

<Proxy http://127.0.0.1:20000/SOGo>
  <IfModule headers_module>
    RequestHeader set "x-webobjects-server-port" "443"
    SetEnvIf Host (.*) HTTP_HOST=$1
    RequestHeader set "x-webobjects-server-name" "%{HTTP_HOST}e" env=HTTP_HOST
    RequestHeader set "x-webobjects-server-url" "https://%{HTTP_HOST}e" env=HTTP_HOST
    RequestHeader unset "x-webobjects-remote-user"
    RequestHeader set "x-webobjects-server-protocol" "HTTP/1.0"
  </IfModule>

  AddDefaultCharset UTF-8
  Require all granted
</Proxy>

# Redirect / to /SOGo/
RedirectMatch ^/$ /SOGo/

# Apple autoconfiguration
<IfModule rewrite_module>
  RewriteEngine On
  RewriteRule ^/.well-known/caldav/?$ /SOGo/dav [R=301]
  RewriteRule ^/.well-known/carddav/?$ /SOGo/dav [R=301]
</IfModule>

# Enable to use Microsoft ActiveSync support
# Note that you MUST have many sogod workers to use ActiveSync.
#ProxyPass /Microsoft-Server-ActiveSync \
# http://127.0.0.1:20000/SOGo/Microsoft-Server-ActiveSync \
# retry=60 connectiontimeout=5 timeout=360
```

---

#### `/etc/cron.d/sogo`

Baked into the image via `cron-sogo`. Mount your own file to override.

```
# Expire stale sessions every 5 minutes (30-minute timeout)
*/5 * * * * sogo /usr/local/sbin/sogo-tool expire-sessions 30

# Send calendar alarms/reminders every 2 minutes
*/2 * * * * sogo /usr/local/sbin/sogo-ealarms-notify

# Send vacation auto-reply (requires sieve credentials file)
* * * * * sogo /usr/local/sbin/sogo-tool update-autoreply -p /etc/sogo/sieve-credentials.creds

# Daily backup (writes to /var/lib/sogo/backups/ by default, keeps 31 days)
30 0 * * * sogo /usr/lib/sogo/scripts/sogo-backup.sh
```

---

### Supervisor-managed services

| Service   | Config file                       |
|-----------|-----------------------------------|
| sogod     | `/etc/supervisor.d/sogod.ini`     |
| apache2   | `/etc/supervisor.d/apache.ini`    |
| cron      | `/etc/supervisor.d/cron.ini`      |
| memcached | `/etc/supervisor.d/memcached.ini` |
