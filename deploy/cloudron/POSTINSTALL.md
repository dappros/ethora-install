This app sets up its own administrator account on first start. The email is
`admin@` followed by the app's domain; the password is generated. To read
it, open the app's Web Terminal and run:

```
grep ADMIN_PASSWORD /app/data/secrets/secrets.env
```

Sign in at the app's address, then change the password in your account settings.
The XMPP server is reached over WebSocket at `/ws` on the same address; the
API lives under `/v1` and `/v2`.
