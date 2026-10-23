# App Privacy answers (App Store Connect)

The App Privacy questionnaire can't be set through the API, so click these in by hand: App Store Connect > Apps > Walkies: Explore Your Suburb > App Privacy (under General), then **Get Started** (or **Edit** next to Data Types).

They match `Walkies/PrivacyInfo.xcprivacy` and the website's privacy policy (`web/src/privacy.html`, live at `/privacy`). If one changes, change all three.

## 1. Privacy Policy URL

`https://walkies.mikecann.app/privacy` (the metadata script sets this too, on the app info).

## 2. Data collection

**Do you or your third-party partners collect data from this app?** Yes, we collect data from this app.

## 3. Data types to tick

| Section | Tick | Why |
|---|---|---|
| Contact Info | **Name** | From Sign in with Apple or Google |
| Contact Info | **Email Address** | From Sign in with Apple or Google |
| Health & Fitness | **Fitness** | Each walk's step count, from the motion chip |
| Location | **Precise Location** | Every walk's GPS points, synced to the account |
| User Content | **Photos or Videos** | Screenshots attached to a "Suggest a feature" request |
| User Content | **Audio Data** | Voice notes attached to a feature request |
| User Content | **Gameplay Content** | Tiles cleared, secrets found, shells, levels, rewards and Shop purchases |
| User Content | **Other User Content** | The places you add, team names, and a feature request's text (and its voice note's transcript) |
| Identifiers | **User ID** | The Walkies account ID |

Leave everything else unticked: Health, Coarse Location (the GPS points are precise), Financial Info, Sensitive Info, Contacts, Emails or Text Messages, Customer Support, Browsing History, Search History (place searches go from the phone to Apple and OpenStreetMap, and the server's street cache is keyed by the place, not the person), Device ID (no push tokens or device IDs), Purchases (nothing to buy), Product Interaction, Advertising Data, Other Usage Data, Diagnostics (no crash or performance reporting leaves the device), Other Data, Phone Number, Physical Address, Other User Contact Info.

## 4. For each ticked type

Apple asks three things per type. The answers are the same for all of them:

1. **How is it used?** Tick only **App Functionality**. (Not Third-Party Advertising, Developer's Advertising or Marketing, Analytics, Product Personalization or Other Purposes.)
2. **Is it linked to the user's identity?** **Yes.**
3. **Is it used for tracking?** **No.**

## 5. Check the preview

The summary on the App Privacy page should read:

- **Data Linked to You:** Contact Info, Health & Fitness, Location, User Content, Identifiers
- **Data Not Linked to You:** none
- **Data Used to Track You:** none

Then **Publish**.
