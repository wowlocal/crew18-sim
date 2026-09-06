# Linux VPS deployment template

This directory is a reviewable deployment base. It is not provisioned to a live VPS.
The Mac continues to run the existing loopback-only Tapflow installation.

## Components

- Caddy exposes the API and the reviewer dashboard on separate HTTPS hostnames.
- The API container stores its SQLite database and verified archives in `control-data`.
- A separately supervised rathole service on the VPS forwards `127.0.0.1:4400` to
  the Mac's `127.0.0.1:4000`. Noise encryption is explicitly enabled.
- The Mac initiates the tunnel; relay and iOS agent stay together on the Mac.
- Reviewers pass the Caddy gateway and then sign into their own Tapflow accounts.
  Participants use the control-plane API through the future portal/bot.

Use one API process and one data volume initially. Host networking in Compose is
intentional and Linux-specific: neither API port 4100 nor tunnel service port 4400
is publicly bound. For a local Mac development session use the native API command.

## Configure

1. Point two DNS records at the VPS. Copy `.env.example` to `.env`, fill in actual
   hostnames, a Caddy password hash, and the reviewed reusable-workflow commit SHA.
2. Install rathole on VPS and Mac. Generate Noise keys with `rathole --genkey`;
   keep the private key on the VPS and give the pinned public key to the Mac.
   Generate a separate random service token. Save private configs with mode `600`.
   The example TOML files require explicit replacement of every `REPLACE_WITH_…` value.
3. Run the server and client under systemd and LaunchAgent respectively. Test
   tunnel reconnection and restart before opening access. See service templates below.
4. On the Tapflow Mac, set `TAPFLOW_TRUSTED_PROXIES=127.0.0.1,::1` in the service
   environment and set the public URL as in `tapflow.remote.config.json.example`.
   With our current launcher, use `export TAPFLOW_TRUSTED_PROXIES=127.0.0.1,::1`
   in the ignored `.tapflow-host/local.env`. Retain the actual dataDir and loopback patch.
   The Node process must receive this exported variable. Restart Tapflow.
5. Permit public 80/443 TCP for HTTPS and 2333 TCP for the encrypted tunnel on the
   VPS. Restrict administrative SSH to the operators. Leave 4000/4100/4400 private.

Caddy overwrites `X-Forwarded-For` with the actual remote peer, and Tapflow trusts
only the local tunnel client. This prevents a tunneled anonymous browser from
being mistaken for an unauthenticated local agent. Test both HTTP and WebSocket
access without credentials from a separate network before inviting users.

## Start

```sh
cd infra/deploy
docker compose --env-file .env config --quiet
docker compose --env-file .env up -d --build
docker compose exec api python -m crew_control.cli create-user \
  --id organizer --role admin --token-file /data/organizer.json
```

Copy the owner-only token file to the operator's password manager/local secret
store; do not print it into CI logs. Create participant and worker tokens with the
same command and appropriate roles. The API intentionally has no public signup.

The source build may require a newer Xcode than the reusable workflow's initial
`macos-15` image. Pin an appropriate runner/Xcode policy per case before the season.
The artifact gate checks deployment target against the case's simulator runtime.

## Storage and recovery

```sh
docker compose exec api python -m crew_control.cli backup --output /data/backup.tar.gz
```

Copy that file to protected off-host storage, then remove the local backup when
retention policy permits. A repeated command refuses to overwrite an existing file.
Back up the Mac's Tapflow data separately; this API backup does not include its
accounts, recordings, or comments. Schedule retention and backup only after choosing
an external storage destination. No scheduled cleanup runs from this template.

After an unclean stop during an upload, stop the API first and use a one-off container:

```sh
docker compose stop api
docker compose run --rm api python -m crew_control.cli recover-uploads
docker compose up -d api
```

Generated prototypes run code supplied by participants. Keep generation/build jobs
away from service credentials, and move simulator execution to a dedicated Mac
account or stronger isolated environment before public use. A simulator clone alone
is not a host security boundary.

## Scope still to connect

This template supplies API hosting and network configuration, not a live external
deployment. Domain/VPS credentials, tunnel keys, reviewer accounts, swift-claw adapter,
GitHub dispatcher, UI/bot and automatic smoke testing are deployment-specific work.
GitHub attestation verification intentionally fails if signer policy, credentials or
account capabilities are unavailable; there is no production bypass flag.

References: [Tapflow self-hosting](https://www.tapflow.dev/guide/self-hosting),
[trusted proxies](https://www.tapflow.dev/reference/configuration),
[rathole transport](https://github.com/rathole-org/rathole/blob/main/docs/transport.md),
[GitHub attestation policy](https://cli.github.com/manual/gh_attestation_verify).
