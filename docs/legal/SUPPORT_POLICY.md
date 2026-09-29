# Ethora Server Support Policy

Version 1.0, effective 29 September 2026.

## Editions and channels

| Edition | How you got it | Support |
|---|---|---|
| Ethora Core, unregistered | self-installed from Docker Hub, GitHub or a marketplace image | community support: documentation, the public issue tracker, and the community forum at https://forum.ethora.com/. Best effort, no response-time commitment. |
| Ethora Core, registered | registered the install for free from the admin panel | the above, plus e-mail support at support@ethora.com and the ticketing system, quoting the license id shown on the License page. Best effort, no response-time commitment. |
| Enterprise, including trials | a signed agreement or trial with Dappros | the support terms in that agreement, which take precedence over this policy |

Marketplace subscriptions (AWS Marketplace, DigitalOcean) fall under the
Core columns unless the listing says otherwise.

## What is supported

- Installation and updates through the documented commands on the supported
  operating systems (Ubuntu 22.04 and 24.04 LTS, x86-64 and arm64).
- The release lines named in the release notes: the current production line
  and the previous one. Older lines receive security fixes only at Dappros's
  discretion.
- The container images published by Dappros, run through the Dappros
  installer. Images rebuilt or modified by you, and installs with hand-edited
  generated configuration, are outside support.

## What to include in a report

Run `deploy/scripts/health-check.sh` and attach its output, the install or
update log, and the log of the failing service (`pm2 logs <service>` or
`docker logs <container>`). Never attach `deploy.yml` or `.deploy.env`: they
contain every secret of your install.

## Security issues

Report vulnerabilities privately to security@ethora.com. Do not open a
public issue. We acknowledge reports within 3 business days and publish a
fix or mitigation before public disclosure where possible.

## Backups and data

You are responsible for backing up your data. The documented backup
procedure is in the runbooks shipped with the installer. Dappros cannot
recover data from an install it does not operate.

## Release cadence

Release lines are named by year and month (`2609`, `2610`). A line receives
fixes for as long as it is the current or previous production line. Upgrade
notes for operators are published with every line.

Contact: support@ethora.com.
