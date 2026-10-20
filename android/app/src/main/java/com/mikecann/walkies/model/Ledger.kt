package com.mikecann.walkies.model

import java.util.UUID

/** The shop and level-reward ledger (Ledger in Progression.swift). Times are seconds since 1970. */
data class Ledger(
    val purchases: List<Purchase> = emptyList(),
    val claims: List<Claim> = emptyList(),
    val spyglasses: List<Spyglass> = emptyList(),
    val equipped: Equipped = Equipped(),
    /** Optional so the original four-field ledger still decodes. First offer wins. */
    val offers: List<Offer>? = null,
) {
    data class Purchase(val id: String = UUID.randomUUID().uuidString, val item: String, val cost: Int, val at: Double)

    data class Claim(val level: Int, val choice: String)

    /** A menu is frozen the first time its level is reached. */
    data class Offer(val level: Int, val choices: List<String>)

    data class Spyglass(val id: String = UUID.randomUUID().uuidString, val secretId: String, val centre: List<Double>, val at: Double)

    data class Equipped(
        val marker: String = "marker.dot",
        val trail: String = "trail.teal",
        val clouds: String = "clouds.classic",
        val cover: String = "cover.red",
        val celebration: String = "celebration.confetti",
        val updatedAt: Double = 0.0,
    )
}

/** What's been sent to the account (SyncState in Sync.swift). Sync itself comes in stage 4. */
data class SyncState(
    val uploadedWalks: Set<UUID> = emptySet(),
    /** The change time of the copy of each city last sent. */
    val uploadedPlaces: Map<UUID, SwiftDate> = emptyMap(),
    val uploadedSecrets: Set<String> = emptySet(),
    /** Canonical JSON of the last ledger accepted by the server. */
    val uploadedProgress: String? = null,
    /** Places deleted on this phone that the server may still have. */
    val deletedPlaces: Set<UUID>? = null,
)
