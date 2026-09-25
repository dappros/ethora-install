# Ethora feature schedule

What each edition of the Ethora server includes and the limits that apply.
This schedule accompanies the [Ethora Core Software License](ETHORA_CORE_LICENSE.md)
and applies to the Release it ships with; a later Release may publish a
different schedule. Version 1.0 draft, 25 September 2026.

## Editions

| | Ethora Core (unregistered) | Ethora Core (registered) | Ethora Enterprise |
|---|---|---|---|
| How you get it | download and install; nothing to do | register the install for free from the admin panel License page (domain name and e-mail address) | an agreement with Dappros; a license key |
| Price | free | free | per agreement |
| Term | no fixed end date for the Release you obtained | same | per agreement |
| Included software (Core Features) | API server, admin panel and web chat, XMPP chat server with the Ethora modules, file storage, and the databases they need | same | Core plus the paid modules below |
| Apps per server | 5 | 10 | unlimited unless the agreement says otherwise |
| User accounts per server | 500 | 5,000 | unlimited unless the agreement says otherwise |
| Support | community: documentation and the public issue tracker | e-mail support at support@ethora.com and the ticketing system, quoting the license id; no response-time commitment | per agreement (SLA available) |
| Updates | new Releases of the Core line as Dappros publishes them, under the licence that accompanies each | same | per agreement |
| "Powered by Ethora" notice | may be shown (reserved; see the licence) | may be shown (reserved) | removable |

The limits apply to creating apps and user accounts on one server. Reaching
a limit refuses the next creation with an explanation in the admin panel and
the API (`LICENSE_LIMIT_REACHED`); it never affects existing apps, accounts,
logins, chat or files.

## Paid Features (Ethora Enterprise)

Available with an enterprise license key, per the applicable agreement:

- Push notifications service (mobile push through APNs and FCM).
- AI agents and document parsing, and the embeddable AI chat widget.
- Compliance and audit logging, including immutable log export.
- Single sign-on and enterprise identity integrations.
- Hosted multi-tenant apps under wildcard subdomains.
- SDK playground and the hosted MCP server.
- High availability and multi-instance deployments.
- Source-code access and source-mode installs.
- Removal of the "Powered by Ethora" notice.
- Service-level agreement and security-update commitments.

An enterprise trial key unlocks the paid features for its stated period;
when it ends the installation continues as Ethora Core with the Core limits.

## Registration data

Registering sends the installation's domain name, the e-mail address given,
an optional company name, the installation identifier and the software
version to `license.ethora.com`, once. Ethora Core installations do not
otherwise contact Dappros. See the [Privacy and Telemetry Notice](PRIVACY_AND_TELEMETRY.md).
