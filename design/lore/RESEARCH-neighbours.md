# Neighbouring suburbs lore: research notes

`busselton-area.json` holds the secrets for the suburbs around Geographe. Each has a `suburb`. Most also have a pin inside that suburb, checked with a point-in-polygon test against its OpenStreetMap boundary. Pins that fell outside, and the farming-locality entries (whose research run couldn't reach the map service), have no pin: those secrets are scattered over their suburb's streets instead.

The research was delegated to other models, each given the same brief: no repeats of `geographe.json`, the same tone and sourcing rules, and First Nations material only from the City of Busselton, the Undalup Association, Landgate naming records with Traditional Owner involvement and DPIRD's Noongar seasons material. Every source URL was then fetched; dead links (404/410) were dropped, and one entry left with no source was cut. Sticker art was drawn by Codex's image tool with the original sticker prompt and two existing stickers as style references, then cut out with `scripts/cutout.swift`.

## Busselton and West Busselton (Claude Opus (claude-gmail))

**How I researched**
- Three sub-agents gathered leads in parallel: town heritage, sea and modern life, and West Busselton. I re-opened the key page behind every fact in every entry myself, except the Cyclone Alby blocks, Rotunda and Phoebe Abbey records, which I re-checked and trimmed.
- Bash had no network access in this sandbox, so everything went through WebFetch. That includes the Nominatim boundary lookups.
- Boundaries were fetched once per suburb with `polygon_threshold=0.0003` (about 30 m of simplification). I then fetched West Busselton's full-detail vertices along its eastern edge, West Street, to check the pins there.
- All 25 pins pass a point-in-polygon test. The closest one to a boundary is the Masonic Lodge pin, about 30 m inside; the full-detail vertices confirm it is on West Busselton's side of West Street. Bodies are 68 to 97 words, with no em dashes or exclamation marks.

**Best sources**
- inHerit records, reached through the SLIP `People_and_Society/MapServer/16` layer. Its envelope query lists every heritage place in a suburb, and `/public/p/<no>` links to the City record.
- Landgate GEONOMA records (Places_and_Addresses layers 9, 10 and 11).
- Collections WA, the City of Busselton (Saltwater pages, the Sugito page), GeoCatch, DWER, the Water Corporation, BD Times, and a 2008 DEC waterbird overview PDF.

**Pins taken from a source**
- From SLIP: Haifordshire Fields, Homestead Park, New River Park and Breeden Park, plus the Seymour/Abbey corner, which is a vertex of a cadastre parcel.
- From OSM: Weld Hall, the drain bridge, and the school footprint (I put the pin on its northern, Bussell Highway edge).

**Pins I estimated** (these are street or foreshore spots I chose; please spot-check them on a map)
- Lighthouse, Courthouse, Saltwater, Vasse Hotel, Esplanade Hotel, Pioneer Cemetery, Cyclone Alby, Cetacean and triathlon.
- St Mary's, the Butter Factory and the Rotunda: the Rotunda pin assumes the river line behind the museum.
- The dredging pin at Rotary Park, Sugito, The Gulch, the Masonic Lodge, and the Road Board office (on High Street, since I couldn't place the lot's Bussell Highway frontage).

**Clustering:** the Queen Street, Marine Terrace and jetty pins sit 50 to 100 m from each other and from the existing Signal Park, Railway House and jetty pins. If a hex can hold only one secret, some of these will need spreading out.

**Entries I'm least sure of**
- **a-sister-town-near-tokyo:** I couldn't find the administration building in OSM, so the pin is a guess at the north end of Southern Drive.
- **the-gulch-on-kent-street:** inHerit has no history text, only the uses, the 1856 date and the 2010 registration. The "Resident Magistrate's Office" comes from the place title alone.
- **family-reunions-only:** I inferred the gloss "in graves where family already lay". The record says only "reunions" in quotation marks.
- **named-for-the-saltwater-people:** the City's 2026 fact sheet calls the opening upcoming, while the project-background page says it "officially opened in May 2026". I used the latter.
- **land-left-for-learning:** this comes from the City's heritage listing as hosted on inHerit. That's the City's own inventory, but it isn't on busselton.wa.gov.au, and Undalup should review it with the other First Nations entries.
- **haifordshire-and-the-hurfords:** the first-woman-hanged claim rests on Freotopia (which cites Purdue 1993 and the Inquirer of 10 October 1855) and Wikipedia. I couldn't open a Trove page or State Records. The subject is dark, so the sticker avoids it. The killer's first name varies between sources (Enoch or William Dodd), so I left it out.
- **holidays-for-the-goldfields:** I don't know whether the hotel building still stands, so the pin is labelled "old Esplanade Hotel site".
- **the-rectors-paddle-steamer:** the source doesn't say where the Jumna sailed, so the body doesn't claim the Vasse River even though the pin is on its bank.

**Verified but left out**
- Jetty fire, December 1999: sources disagree on 65 m, 70 m or 150 m.
- The solar jetty train, CinefestOZ (no venue to pin), and the railway station that was moved twice (it now sits at the existing Railway House pin).
- Villa Carlotta, St Davitt's, Paisley Cottage, Lime Kiln Park (only the bare name record), the Broadwater waterbird count (Broadwater Lake is in Broadwater suburb), and the Merenj Boodja garden (no meaning for the name in the approved sources).
- Yoganup Park and the Gaywal statue: kept out on purpose, following RESEARCH.md.

## Wonnerup, Vasse, Abbey and Broadwater (Codex)

- **Research drafts only, not import-ready. The mandatory point-in-polygon checks were not completed. No pin is verified inside its requested OSM boundary.**
- Read `design/lore/RESEARCH.md` and all 40 entries in `Walkies/Lore/geographe.json`, including the outside-Geographe stories. Avoided their existing facts and IDs.
- Opened every URL included in the entries. Checked body lengths, title lengths, required keys and ID uniqueness. Counts: Wonnerup 8, Vasse 6, Abbey 5, Broadwater 4.
- Best sources were the individual inHerit records and assessment documents, City coastal reports, DBCA’s wetlands document, DWER’s Buayanyup account and the school’s own history.
- **All 23 coordinates are estimates.** Road frontage, footpath and shore placement are intended placements, not verified public-access or cadastral findings. Some estimates may need substantial movement.
- The duck hide, military target and former river connections use representative roadside pins. Their exact physical locations were not established, and visibility from those pins is not claimed.
- Otto’s beach pin is representative. The [Museum page](https://visit.museum.wa.gov.au/boolabardip/ottos-symphony) gives both 1897 and 1898 for the stranding, so the body omits the year.
- Least certain: **The Secondhand Classroom**. The Heritage Council assessment says Cowaramup; the [school history](https://vasseps.wa.edu.au/about-us/) says Treeton. The draft explicitly attributes Cowaramup to the assessment.
- **Land For Lessons** follows the Heritage Council’s 1884 teacher-house date; the [National Trust’s 2022 brief](https://www.nationaltrust.org.au/wp-content/uploads/2022/05/20220524-Wonnerup-House-project-brief.pdf) gives 1885.
- The three DBCA wetland-history entries cite the opened **2019 draft**, not the final plan. Broadwater’s older survey findings remain explicitly dated to 2005.
- **Sandbags Hold The Beach** distinguishes existing western groynes from the proposed eastern replacement; completion of that replacement was not verified.
- Historical and ecological facts are source-backed. Pin placement, representative viewing locations and illustration choices are my inferences.
- Left out the massacre and new First Nations material. No restricted cultural material was used.
- No files were modified.

Automatic approval review rejected the browser’s Nominatim request because network egress to that origin was not authorised. I stopped boundary retrieval; the required polygon validation remains outstanding.

## Farming and forest localities (Codex)

- **Incomplete spatial work:** these are 25 researched story drafts. Every `place` is deliberately `null`; none has a verified public pin or a completed point-in-polygon test. They are not ready for ingestion as unlockable secrets.
- Read `Walkies/Lore/geographe.json` and `design/lore/RESEARCH.md` first. Checked existing stories, including outside-Geographe entries, and verified no ID clashes. Bodies are 58–71 words.
- Opened every URL listed in `sources`. Best material came from Heritage Council assessments, City management plans, State Library oral histories, contemporary ABC reporting and DWER.
- **Verified versus inferred:** bodies report facts or attributed recollections from those sources. Suburb assignments remain provisional interpretations of source locations, not verified OSM boundary membership. No coordinates were estimated.
- **Spatial priorities:** check the lime kilns against Stirling Estate, the geological reference locality against Yoganup, the original North Jindong school site, and the research dairy against Kalgup. Historical district names do not establish modern locality boundaries.
- **The Flatpack Attic:** prefabrication is the heritage assessor's interpretation of numbered joists, so the body preserves “may”.
- **School and hall dates:** Jindong's record gives a 1930 construction field but documents a school by 1925. Carbunup's record gives 1920 in its construction field but describes tenders in 1930. Bodies distinguish the school history and tender evidence from definite building dates.
- **Oral histories:** the Acton Park coffee and Jindong orchid stories are explicitly attributed recollections. The wildflower transcript disputes the first show's year, so that date is omitted.
- **A Little Catalonia:** used the Museum biography, excluding disputed vineyard claims in visitor comments. The Ludlow planting figure is a 2019 target, not a verified achievement.
- No First Nations translations or cultural stories were added. No files were modified.

Automatic approval review rejected browser access to Nominatim because network access was declined. Consequently, the mandatory boundary verification remains unfinished.
