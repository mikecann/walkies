# Releasing Walkies to the App Store

Every step from here to "Submitted for review" for v1, copied from Poddle's (same team, same API key).

## What Mike decided (23 Oct 2026)

- **Free**, **iPhone only**, **worldwide**, version **1.0.0**, released **manually** once it's approved.
- **Sign-up is open** to anyone with Apple or Google, each person with their own account. There's no allowlist in the code; the only gate was Google's consent screen being in Testing (step 2).
- Apple requires in-app **account deletion** for apps with sign-up: Settings > Delete account (`users:deleteAccount`, `convex/accountDeletion.ts`).
- Support email `walkies@mikecann.app`. Privacy policy and support pages are on the website: https://walkies.mikecann.app/privacy and /support.

The App Store Connect app already exists: **Walkies: Explore Your Suburb**, Apple ID `6826001880`, bundle `com.mikecann.walkies`, SKU `walkies-ios`, primary language English (Australia). The Paid Applications agreement is accepted. The scripts use the team's Admin API key `~/.config/poddle/AuthKey_7SS6J9F98P.p8` (key `7SS6J9F98P`, issuer `69a6de6f-a06e-47e3-e053-5b8c7c11a4d1`). Never print it. The App Review contact's phone number comes from `~/.config/poddle/review-contact.json`, never from the repo.

Prod is `savory-bee-296` (Sydney). Commands with `--prod`, and `npx convex deploy`, hit prod; nothing else here does. Run everything from the repo root.

## 0. Before you start

- `npx tsc -p convex --noEmit`, `npm test -- --configLoader runner` and the iOS tests (README) pass.
- `appstore/metadata.json` has been read and okayed by Mike: name, subtitle, description, keywords, promotional text, categories, age rating answers and review notes.
- On dev, deleting a test account works end to end: a Debug simulator build, Test sign-in, walk a bit with `scripts/sim-walk.sh`, then Settings > Delete account. It should ask twice, sign out, and `npx convex run accountDeletion:remaining '{"userId":"<id>"}'` should show zeros a few seconds later.
- `https://walkies.mikecann.app/privacy` and `/support` load.

## 1. Deploy the backend

```sh
npx convex deploy
```

This brings `users:deleteAccount`, the `accountDeletions` table, `users.deletedAt` and its `by_mergedInto` index, and the hourly "resume account deletions" cron. It's all additive, so existing users are untouched. Check the deploy output has no schema errors.

## 2. Open Google sign-in to everyone

Google's consent screen for the Walkies project (`walkies-512104`, on mike.cann@gmail.com) is in **Testing**, so only the listed test users can sign in with Google. App Review signs in with their own account, so this has to change **before** submitting or "Sign in with Google" fails for them.

console.cloud.google.com > the Walkies project > Google Auth Platform > Audience > **Publish app**, and confirm "In production". Walkies only asks for the basic scopes (name, email, photo), so Google doesn't need to verify it first.

Then check prod has no test sign-in switched on:

```sh
npx convex env list --prod | awk -F= '/^[A-Z][A-Z0-9_]*=/{print $1}'
```

The list must **not** have `WALKIES_TEST_SIGNIN`.

## 3. Warm the street cache for Cupertino

App Review is usually in Cupertino and the review notes suggest adding it. The first fetch of a place asks Overpass, which is often slow or down, so add it once yourself first: sign in on a prod build (TestFlight, after step 7, or any Release build on a phone), add Cupertino, and delete it again. Its streets then stay in the shared `placeData` cache for 60 days and anyone adding it gets them straight away.

## 4. Set the listing

```sh
node scripts/appstore-metadata.mjs --dry-run   # read what it would change
node scripts/appstore-metadata.mjs             # change it
node scripts/appstore-metadata.mjs --dry-run   # should say "Everything's up to date."
```

It sets the content rights declaration (OpenStreetMap's streets and the Wikimedia Commons photos in the secrets are third-party content), the categories (Health & Fitness, then Lifestyle), the en-AU name, subtitle and privacy policy URL, the 1.0.0 version's copyright, manual release, description, keywords, promotional text, support and marketing URLs, the age rating answers, a free price, worldwide availability, and the App Review contact and notes.

It lists age rating questions it can't answer as "still unanswered". Answer those in App Store Connect > App Information > Age Rating: Walkies has no social media features, isn't made for kids (leave the kids age band off), and the Korea and age rating URL fields can stay empty.

## 5. App Privacy

Click through `docs/runbooks/app-privacy-answers.md` in App Store Connect > App Privacy, then **Publish**.

## 6. Screenshots

The App Store needs the **6.9-inch iPhone** size, **1320 × 2868** (portrait). Smaller iPhone sizes are scaled from it. They come from **sample data only** (`Walkies/Services/ScreenshotMode.swift`): a made-up explorer called Sam a few weeks into Fremantle, who's also had a long weekend in Busselton, built from `appstore/sample/*.json`. Never anyone's real walks.

```sh
scripts/screenshots.sh map recap recap-end secrets progress walks
```

It builds Debug, makes (or reuses) an "iPhone 17 Pro Max" simulator on iOS 27.0, sets the status bar to 9:41 with full battery and the location to the middle of Fremantle, and saves each screen to `appstore/screenshots/`. `UDID=<id>` picks a particular simulator instead, which is handy when other simulators are busy. Check them with `sips -g pixelWidth -g pixelHeight appstore/screenshots/*.png`, look at each one, then upload in this order (it replaces whatever's in the 6.9" slot):

```sh
node scripts/appstore-screenshots.mjs appstore/screenshots/{map,recap,recap-end,secrets,progress,walks}.png
```

No iPad screenshots: v1 is iPhone only. If the sample suburbs ever need remaking, `node scripts/make-screenshot-sample.mjs` (Fremantle) and `node scripts/make-screenshot-sample.mjs 11688699 busselton`, then `bash scripts/test-screenshot-sample.sh` checks Fremantle is part explored and the weekend finds some secrets.

## 7. Upload a build

```sh
scripts/appstore-upload.sh            # archive, export and validate; stops before uploading
UPLOAD=1 scripts/appstore-upload.sh   # the real thing
```

It archives Release for iOS (prod backend only, version 1.0.0), sets the build number to the UTC time as `YYMMDDHHMM`, refuses to go on if the binary mentions the dev deployment, exports with cloud-managed App Store signing through the API key, validates with `altool`, and with `UPLOAD=1` uploads. Note the build number it prints. Processing takes 5 to 30 minutes; App Store Connect emails when it's done.

`ITSAppUsesNonExemptEncryption` is `NO` in `Config/Info.plist` (Walkies only uses HTTPS), so there's no export compliance question.

## 8. Attach the build

```sh
node scripts/appstore-submit.mjs <build number>
```

It waits for the build to finish processing, attaches it to 1.0.0, and sets manual release and third-party content again. It stops there; `--submit` (step 10) is what sends it to App Review.

## 9. Final checks in App Store Connect

On the 1.0.0 version page and App Information, check:

- Screenshots are there for iPhone 6.9".
- Promotional text, description, keywords, support and marketing URLs are filled in, and the version is 1.0.0 with copyright "2026 Mike Cann".
- App Review Information: sign-in required is **off**, the contact name, email and **phone** are filled in, and the notes are there.
- App Information: name "Walkies: Explore Your Suburb", subtitle, categories Health & Fitness and Lifestyle, privacy policy URL, age rating, content rights ("contains third-party content").
- Pricing and Availability: Free, all countries and regions.
- App Privacy: published.
- Version Release: "Manually release this version".

## 10. Submit

```sh
node scripts/appstore-submit.mjs <build number> --submit
```

Or **Add for Review** at the top right of the version page, answer anything it still asks, then **Submit to App Review**. The status goes to "Waiting for Review".

## Once it's approved

It waits for you, since release is manual: App Store Connect > the version > **Release this version**. Then set `APP_STORE_LIVE` to `true` in `web/site.mjs` and run `npm run web:upload:prod`, so the website's badges link to the App Store.

## If it's rejected

Read the message in App Store Connect > Resolution Center. Fix it, bump nothing (the version stays 1.0.0), upload a new build with `UPLOAD=1 scripts/appstore-upload.sh` (it gets a new build number), attach it with step 8 and resubmit. `node scripts/appstore-submit.mjs <build> --submit` does the attach and the resubmit: it marks the rejected item resolved and resubmits the rejected submission, because a fresh submission is refused. The rejection message itself is only in App Store Connect > App Review, not the API.

App Store Connect's **Resubmit to App Review** button stayed greyed out in October 2026, even after the build was attached, so use the script. Check the version page for a "This item requires your attention" box too. That time it asked for Apple's new **Regulated Medical Device** declaration (App Information > Declare Regulated Medical Device), and Walkies is declared not a medical device. Listing-only fixes just need the metadata script again and a resubmit.
