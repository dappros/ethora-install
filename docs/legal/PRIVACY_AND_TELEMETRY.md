# Ethora Server: Privacy and Telemetry Notice

Version 1.0, effective 29 September 2026. Controller for the data described
here: Dappros Ltd (company number 11455432), 38 Munden Grove, Watford, WD24 7EE, United Kingdom,
privacy@ethora.com.

This notice describes what an Ethora Server install sends to Dappros. Your
users' data (messages, files, accounts) is stored on your servers and is
never sent to Dappros by the Software.

## 1. Registration (Ethora Core)

An Ethora Core install contacts Dappros only if you register it, from the
admin panel License page. That single request sends the install's domain
name, the e-mail address and optional company name you enter, the
install's random identifier and the software version to
`license.ethora.com`, and receives the registration key. Purpose: to issue
the key, apply the registered limits, and offer you support. Legal basis:
performance of the licence agreement. Retention: for as long as the
registration exists plus 12 months. An unregistered Core install sends
nothing to Dappros.

## 2. License call-home (enterprise keys)

When a license server address is configured in `deploy.yml`, the install
contacts that server once a day and once shortly after each start. It
sends:

- the install's random instance identifier and the license key identifier,
- the domain the key is bound to and the hostnames the install serves,
- the license state (licensed, grace, restricted) and the key's expiry,
- the software version, build commit and Node.js version,
- the number of apps and the number of user accounts on the install (counts
  only, no names or content),
- and, as with any web request, the public IP address the request comes from.

Purpose: to renew keys automatically, enforce the instance limit in the
license, and know which versions are in use. Legal basis: performance of the
license agreement and Dappros's legitimate interest in operating the
licensing service. Retention: instance records are kept for the life of the
license plus 12 months.

You can switch call-home off (`license.call_home: false`) or leave the server
address empty; keys keep working offline. Core registration keys and keys
issued as offline keys never require call-home.

## 3. Trial key requests

Requesting a trial key on `license.ethora.com` sends the domain, e-mail
address, optional company name and the IP address of the request. We use
them to issue the key, prevent duplicate trials, e-mail you the key, and
contact you about your trial. Retention: 24 months after the trial ends.

## 4. What is not collected

The Software does not send crash reports, usage analytics or any content of
chats, files or user profiles to Dappros. Third-party services you configure
yourself (an AI provider, push notification services, e-mail delivery,
analytics keys in the admin panel) receive data according to their own
terms; the Software only sends to them what you configure.

## 5. Your rights

Where GDPR or similar law applies, you may ask for access to, correction of,
or deletion of the personal data above, and object to processing based on
legitimate interest, by writing to privacy@ethora.com. You may complain to
your supervisory authority.

## 6. Changes

This notice ships with each release of the Software and applies to that
release. The current version is published at https://ethora.com/legal.
