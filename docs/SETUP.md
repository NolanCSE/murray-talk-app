# Murray iPhone app — what only you can do

Everything else is built and tested here. These six
steps need your Apple ID and your GitHub account. Roughly 45 minutes,
most of it waiting on Apple.

1. **Apple Developer Program** — https://developer.apple.com/programs/enroll/
   as an individual, $99/year. Approval is usually same-day, sometimes 48 h.
   Note your **Team ID** (Membership details).

2. **App Store Connect API key** — App Store Connect → Users and Access →
   Integrations → App Store Connect API → Team Keys → "+". Name it
   `murray-ci`, role **App Manager**. Download the `.p8` **once** (Apple
   never shows it again). Note the **Issuer ID** and **Key ID**.

3. **Register the app** — App Store Connect → Apps → "+" → New App.
   Platform iOS, name `Murray`, bundle ID `com.nolancse.murraytalk`
   (create it there if the picker is empty), SKU `murray-talk`. This is only
   a record; nothing is submitted to review, ever.

4. **GitHub secrets** — this repo → Settings → Secrets and variables → Actions

   | name | value |
   |---|---|
   | `TALK_URL` | the full talk URL from your phone's bookmark, `https://…/talk/<secret>/` — trailing slash included |
   | `APPLE_TEAM_ID` | from step 1 |
   | `ASC_ISSUER_ID` | from step 2 |
   | `ASC_KEY_ID` | from step 2 |
   | `ASC_KEY_P8` | `base64 -w0 AuthKey_XXXX.p8` — the whole file, one line |

   Nothing here ever appears in a log; the workflow was written and tested
   so that it can't.

5. **Run it** — Actions → "iOS app" → Run workflow → branch `main`. The
   first signed run also creates the signing certificate and profile in
   your account (that is what `-allowProvisioningUpdates` does). ~15 min.
   If the archive step fails on "no profiles / bundle id", step 3 wasn't
   finished.

6. **Install** — TestFlight app on the iPhone → the build appears under
   "Murray" (you are an internal tester automatically as the account
   holder; if not: App Store Connect → TestFlight → Internal Testing → add
   yourself). Tailscale must be connected on the phone. First launch asks
   for the microphone.

Then tell me what the first launch did — in particular whether the mic
survives locking the screen mid-call. That answer decides phase 2.

## Before any of that, to just look

- Screenshots of the real page in an iPhone viewport: the screenshots in the private murray repo
- The real iOS build in a simulator: Actions → latest "iOS app" run →
  artifact `simulator-capture` (`sim-1-start.png`, `sim-2-offline.png`,
  `launch.mp4`). No Apple account needed for this.
