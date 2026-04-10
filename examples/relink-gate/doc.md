# Authentication

The `login` function validates a username/password pair against the
database and returns a session token on success.

```
login(username, password) -> session_token
```

It rejects empty passwords and usernames shorter than 3 characters.
