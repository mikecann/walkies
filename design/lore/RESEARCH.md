# Geographe lore: research notes

`geographe.json` has 40 entries. 16 are pinned inside Geographe, 18 are pinned outside it, and 6 have no pin.

Categories: history 11, the-sea 8, first-nations 7, nature 6, modern-life 4, odd-records 4.

## How this was researched

- **The Geographe material I did myself.** That covers the marina, the canals, the beach, the parks and the homesteads.
- **Three sub-agents ran in parallel on the wider area:**
  - the Baudin expedition, settlement, shipwrecks and whaling
  - the jetty, events and modern Busselton
  - Wardandi heritage and wildlife

  Before using any of their facts, I re-opened the key pages myself and checked them: WA Museum wreck records, ADB, Trove, DWER, GeoCatch, DBCA, Undalup, City of Busselton, ABC and the jetty swim site.
- **Where the best material came from:**
  - **Heritage Council inHerit records.** I located these through the WA Government SLIP heritage layers ("People_and_Society" MapServer layers 7, 9 and 16), which also give each place a polygon.
  - **Landgate's official place-name records (GEONOMA).** These come through the SLIP "Places_and_Addresses" MapServer. They contain the origin notes for park, canal and reserve names. Several were suggested or verified by Traditional Owners. The `sources` URLs for these are live ArcGIS queries that return the record as JSON.
  - **The 2010 seagrass wrack synopsis** by UWA, ECU and DHI, hosted by the Department of Transport.
  - **ABC's 2022 report** on the Port Geographe seaweed.
- **First Nations entries use only these sources:**
  - City of Busselton
  - the Undalup Association
  - Landgate naming records that note Traditional Owner involvement
  - DPIRD's Noongar seasons fact sheet

  No sacred or restricted material is included. Before shipping, show those 7 entries to the Undalup Association (undalup.com), which shares Wadandi culture publicly and does this kind of review.

## Coordinates

- **Inside Geographe.** I tested every pin against the actual suburb polygon: the OpenStreetMap PSMA admin boundary for Geographe, a point-in-polygon check rather than a bounding box. All 16 pins marked `insideGeographe: true` pass. Every pin marked false is outside it.
- **The suburb's northern edge is the waterline.** That puts the breakwater tips and the sea just outside it. Beach pins therefore sit 10 to 40 m inland of the OSM coastline, on the sand or dune.
- **Spots nobody can walk onto got moved:**
  - **Private homes.** Sandilands and Beachgrove are pinned on the nearest public street (Sadlier Link and Beachgrove Place), not on the house.
  - **Water.** The canal-names sticker is on the canal footbridge, and the estuary sticker is on Layman Road where it runs right along the Vasse Estuary shore.
- **These coordinates are estimated rather than taken from a source:**
  - **Western Beach** (seaweed-mountains, the-one-per-cent-trick): I chose spots on the beach west of the western breakwater. Neither source fixes a point.
  - **Former Moonlight Bay** (-33.62742, 115.39696): this is the shoreline just east of the marina entrance, which is where the 2010 synopsis describes the "two pocket beaches". The old groynes' exact positions aren't confirmed.
  - **Western breakwater base** (-33.63080, 115.38790), **marina entrance path** (-33.63130, 115.39050) and **school footpath** (-33.63918, 115.37733): taken from OSM geometry.
  - **Jetty halfway point** (-33.63657, 115.34050): a vertex of the OSM jetty polygon.
  - **Heritage places** (floodgates, Chapman's Mill, Pigeon Grove, Ford Road crossing, Fairlawn, sundial, Waljin garden, old campsite): centroids of the heritage polygons, so they mark the lot rather than an exact feature.
  - **Chapman's Mill, Pigeon Grove, Cattle Chosen and Fairlawn are private property, all outside Geographe.** If the app needs them to be unlockable, move those pins to the road frontage.
  - **Tuart forest:** pinned at Membenup Picnic Area (OSM) as a representative spot.
- **These coordinates come straight from a source:**
  - wreck of the Mary (WA Museum record)
  - Underwater Observatory (OSM building)
  - Landgate name points: Koolangka, Kwilena, Woodhenge, Wunda-Buri, Wonnerup Inlet, Herring St beach access

## Entries I'm least sure of

- **canals-with-sailing-names and geographes-woodhenge.** The "approved in August 2023" claim comes from the `date_approved` field in Landgate's records (2023-08-29 for all the marina park and canal names). The canals plainly existed earlier, so this reads as the formal approval date, and the bodies say "formally approved". It is still a database field, not a news report.
- **kwilena-means-dolphin.** The park name and its meaning are Wardandi and suggested by Traditional Owners, per Landgate. The story about people fishing with dolphins comes from a DPIRD fact sheet that credits BoM and the Cities of Melville and Stirling. So it is general Noongar knowledge, not specifically Wardandi, and the body attributes it to the fact sheet.
- **sails-like-shields.** Landgate's record cites historian Neville Green and says "probably". The body keeps the "probably".
- **moonlight-bay.** The facts are solid; only the pin location is approximate (see above).
- **the-sundial-in-the-scrub.** The heritage record frames the disappearance as "one story, probably founded on fact". The body says "as the story goes".
- **wa-first-cheese-factory.** There is one source: the City heritage record, citing a Busselton Historical Society loose-leaf. It gives no date beyond "about the turn of the century" for the leases.
- **the-windmill-that-waited.** The two heritage records disagree on whether it was WA's "first commercial flourmill", so I left that claim out. The body only uses details from the 1996 assessment.
- **chasing-deep-water.** Sources give the jetty's length as 1,841 m (Collections WA), 1.8 km (City), 1.82 km (WA Government, 2014) or about 1,820 m (Heritage Council). I used 1,841 m and the City's wording, "longest wooden piled jetty in the Southern Hemisphere".
- **thirty-five-million-kilos-of-salad.** GeoCatch calls Geographe Bay's meadow the "second largest in WA" on one page and "one of the most extensive" on another. The 35 million kg figure is for the 2008 to 2009 study period.
- **the-sailor-who-gave-us-vasse.** Every survival story is hearsay; the body presents them as claims. Vasse's rank varies by source, so the body just says "a seaman".
- **Spelling varies across sources:**
  - Wardandi / Wadandi: I used the spelling each source uses.
  - Lockeville / Lockville: I used WA Museum's Lockeville.
  - Ballaarat / Ballarat: the engine is spelled Ballaarat, the town Ballarat.
  - Ngwayir / Nguraren for the ringtail possum: I used the City's ngwayir.

## Left out

**Couldn't verify:**
- Resident dolphins in the Port Geographe canals. The only sources were real estate listings.
- Sea lions on the groynes, kangaroos on Geographe beaches, leafy seadragons at the jetty. Search snippets only.
- Wonnerup meaning "place of fire". Official sources say "place of the women's digging stick".
- "Wadan Wattern" as a Wadandi name for Geographe Bay. It appears in one conference abstract only; ask Undalup before using it.
- The DBCA Landscope piece with Elder Dr Wayne Webb on mammang (whales) and strandings meaning "ancestors coming home". A sub-agent found it but I didn't open it myself, and it is cultural content worth checking with Undalup first.
- Southern right whales calving in Geographe Bay, humpback timing (September to December), blue whale counts. These came from operator figures or PDFs that wouldn't load.
- Baudin's crew building a stake fish trap at Wonnerup. The source page was blocked.
- "Riviera of the West", a jetty start date of 1853, and a Busselton Jetty ultra event. No supporting source was found for any of them.

**Left out deliberately:**
- **The 1841 killing of settler George Layman by the Wardandi elder Gaywal at Wonnerup, and the reprisal killings of Wardandi people that followed** (Perth Gazette, 1841; National Trust WA). This is real and important history, but a cute collectible sticker is the wrong format for a massacre. The same goes for the 2019 bronze statue of Gaywal on Queen Street. If you want it in the app, it should be written with Wardandi input, probably not as a sticker.
- **Yoganup Park.** Landgate's record says the name means "place of the wild dog" and refers to a thylacine song-line. It is public and Undalup collaborated on it, but song-lines felt too close to cultural knowledge to turn into a fun sticker without asking.

**Verified, but cut to stay at 40 entries** (the sources are good if you want more stickers later):
- **Busselton's timber lighthouse (1873 to 1933).** It was 70 ft high, its kerosene lamp could be seen 21 miles out, and a ship's bell was rung for arrivals. Source: collectionswa.net.au/items/18d21af5-b874-4986-956a-890615870fc2
- **Jetty relic bricks.** After Cyclone Alby (4 April 1978), polished jarrah blocks from the wreckage were sold for $2 each, stamped "BUSSELTON JETTY RELIC". Source: collectionswa.net.au/items/a954dccc-11e3-4481-a2e9-cf5a8d86d49d
- **Grace Bussell and the Noongar stockman Sam Isaacs**, who rode into the surf to rescue passengers from the Georgette in 1876. The wreck site is near Calgardup, well outside the bay, and sources disagree on the date and the death toll. Sources: slwa.wa.gov.au/stories/slwa-abc-radio/georgette-rescue and museum.wa.gov.au/maritime-archaeology-db/wrecks/id-1160
- **The first Jetstar flight from Melbourne** (6 April 2022, 186 passengers), after eight false starts. Source: abc.net.au/news/2022-04-06/melbourne-to-margaret-river-busselton-direct-flights-launched/100969294
- **The July 1840 gale** that wrecked three American whalers in Geographe Bay and Koombana Bay. Sources: museum.wa.gov.au wreck records id-1196 and id-1565
- **The Castle Bay whaling station (1845 to 1872).** Source: inHerit 4bc6307b-a5ba-42a0-8501-2228746fd84e
- **St Mary's Church (opened 1845)**, one of WA's oldest churches. The heritage record says "one of the oldest", not "the oldest".
- **Underwater observatory replacement.** "The Cetacean", a whale-shaped replacement observatory, was shelved after a $25 million cost blowout. Source: bdtimes.com.au
- **Ironman WA in Busselton since 2004**, and CinefestOZ since 2008.
- **Wonnerup House (1837 to 1859).** A National Trust property.
- **The Ballarat mill site** at the Vasse Estuary mouth, home of "the first private railway line in Western Australia". Source: inHerit f4214ecd-cced-4c6a-ba34-ea8b40527cc5
