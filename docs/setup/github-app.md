# GitHub App setup (development)

The API uses a GitHub App to create one issue per approved spec and to follow the pull requests linked to it. It also
lists a board repository's open issues so you can import one as a card; approving that card's spec posts the spec as one
comment on the issue (a later approved version edits the same comment) and never touches the issue's title or body. Register
one app for development; use a separate one for production later. Takes about 15 minutes.

The private key and the webhook secret are the only secrets. Neither goes in the repository, in chat, or in the
Flutter build.

## 1. Start a webhook tunnel

GitHub has to reach your machine to deliver webhooks. The API receives them on a separate local port (8081) that serves
nothing else, so the tunnel never exposes the rest of the API, including dev sign-in.

```sh
cloudflared tunnel --url http://localhost:8081
```

It prints a `https://<random>.trycloudflare.com` URL. Keep it running; the URL changes each time you restart it, and
then the app's webhook URL needs updating (step 6).

## 2. Create a webhook secret

This writes a random secret to `services/api/.env` (gitignored) and copies it to the clipboard without printing it:

```sh
cd services/api
secret=$(openssl rand -hex 32) && printf 'GITHUB_WEBHOOK_SECRET=%s\n' "$secret" >> .env && printf %s "$secret" | pbcopy; unset secret
```

## 3. Register the app

Profile picture → **Settings** → **Developer settings** → **GitHub Apps** → **New GitHub App**.

| Field | Value |
| --- | --- |
| GitHub App name | Something unique, e.g. `ai-kanban-dev-<yourhandle>` |
| Homepage URL | Your repository's URL |
| Callback URL | Leave empty |
| Expire user authorization tokens | Keep checked |
| Request user authorization (OAuth) during installation | Leave unchecked |
| Enable Device Flow | Check (sign-in with GitHub will use it later) |
| Setup URL | Leave empty |
| Webhook → Active | **Checked** |
| Webhook URL | `https://<random>.trycloudflare.com/github/webhook` from step 1 |
| Webhook secret | Paste from the clipboard (step 2) |
| Where can this GitHub App be installed? | **Only on this account** |

**Repository permissions** (everything else stays "No access"):

| Permission | Access | Why |
| --- | --- | --- |
| Contents | Read-only | The PR query reads each linked PR's head commit and its CI status; GitHub may require this for commit data (unverified until a real install; there is no cloud worker that clones) |
| Issues | Read and write | One issue per approved spec; listing and importing open issues; the spec comment on an imported issue (issue comments need nothing more) |
| Pull requests | Read-only | Linked PRs and their reviews |
| Checks | Read-only | CI status |
| Commit statuses | Read-only | CI status from older CI systems |
| Metadata | Read-only | Required; set automatically |

**Subscribe to events:** Issues, Pull request, Pull request review, Check run, Check suite, Status.

Account and organization permissions: none. Click **Create GitHub App**.

## 4. Private key

On the app's page, note the **Client ID**. Under **Private keys**, click **Generate a private key**, then move it out of
Downloads and lock it down:

```sh
mkdir -p ~/.config/ai-kanban
mv ~/Downloads/ai-kanban-dev-*.private-key.pem ~/.config/ai-kanban/github-app.pem
chmod 600 ~/.config/ai-kanban/github-app.pem
```

Don't generate a client secret; nothing uses one.

## 5. Install it and configure the API

**Install App** → your account → **Only select repositories** → pick a test repository → **Install**.

Add to `services/api/.env`:

```sh
GITHUB_APP_CLIENT_ID=Iv23li...
GITHUB_APP_PRIVATE_KEY_PATH=/Users/<you>/.config/ai-kanban/github-app.pem
```

`npm run dev` reads `.env`. The API logs `GitHub sync on` at start, or what's missing.

## 6. When the tunnel URL changes

App settings → **General** → **Webhook URL** → paste the new URL with `/github/webhook` → **Save changes**. Deliveries
GitHub couldn't send in the meantime can be redelivered from **Advanced → Recent Deliveries**.

## Security

- The key lets anyone act as the app on every repository it's installed on: read code and create issues. Keep it at
  mode 600 outside the repository.
- Until sign-in with GitHub checks access, anyone who can reach the API can point a board at any repository the app
  is installed on and file issues there, and also read its open issues (and import their bodies). Keep the API on
  localhost (the default) and install the app only on repositories you own.
- An imported issue's title and body become the card's brief, which the Refiner reads: anyone who can open issues on
  the repository writes briefs for it. The Refiner stays read-only either way (it can only read, list, glob and grep a
  copy of the checkout), and the spec it writes is posted only after a person approves it.
