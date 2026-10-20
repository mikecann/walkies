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
    ) {
        operator fun get(group: Progression.Group): String = when (group) {
            Progression.Group.Marker -> marker
            Progression.Group.Trail -> trail
            Progression.Group.Clouds -> clouds
            Progression.Group.Cover -> cover
            Progression.Group.Celebration -> celebration
        }

        fun with(group: Progression.Group, item: String): Equipped = when (group) {
            Progression.Group.Marker -> copy(marker = item)
            Progression.Group.Trail -> copy(trail = item)
            Progression.Group.Clouds -> copy(clouds = item)
            Progression.Group.Cover -> copy(cover = item)
            Progression.Group.Celebration -> copy(celebration = item)
        }
    }

    /**
     * Another phone's ledger folded into this one (Ledger.merged in Progression.swift):
     * every purchase and spyglass once, the first claim and offer for each level, and
     * the most recently changed equipment. The receiver wins duplicate ids, levels and
     * equal equipment times; on sync the server is the receiver.
     */
    fun merged(other: Ledger): Ledger {
        val ids = HashSet<String>()
        val levels = HashSet<Int>()
        val offerLevels = HashSet<Int>()
        val glasses = HashSet<String>()
        val offers = (this.offers.orEmpty() + other.offers.orEmpty()).filter { offerLevels.add(it.level) }
        return copy(
            purchases = (purchases + other.purchases).filter { ids.add(it.id) },
            claims = (claims + other.claims).filter { levels.add(it.level) },
            spyglasses = (spyglasses + other.spyglasses).filter { glasses.add(it.id) },
            offers = offers.ifEmpty { null },
            equipped = if (other.equipped.updatedAt > equipped.updatedAt) other.equipped else equipped,
        )
    }

    /** Freezes a menu for every level reached that hasn't got one yet. */
    fun preparedPicks(xp: Int): Ledger {
        var offers = this.offers
        for (level in Progression.pendingLevels(xp, this)) {
            if (offers.orEmpty().any { it.level == level }) continue
            offers = offers.orEmpty() + Offer(level, Progression.picks(level, owned))
        }
        return if (offers == this.offers) this else copy(offers = offers)
    }

    fun picks(level: Int): List<String> = offers?.firstOrNull { it.level == level }?.choices ?: Progression.picks(level, owned)

    val spent: Int get() = purchases.sumOf { it.cost }

    /**
     * Reward bags are spending money, not walking XP, so claiming one can't grant
     * another level by itself. They also never count as tiles or quest progress.
     */
    val rewardShells: Int get() = claims.count { it.choice == Progression.SHELL_BAG } * 50

    fun balance(earned: Int): Int = earned + rewardShells - spent

    val owned: Set<String>
        get() {
            val out = Progression.catalog.filter { it.isFree }.mapTo(LinkedHashSet()) { it.id }
            for (p in purchases) if (Progression.item(p.item)?.group != null) out.add(p.item)
            for (c in claims) if (Progression.item(c.choice)?.group != null) out.add(c.choice)
            return out
        }

    /**
     * A losing offline claim can leave its cosmetic equipped but no longer owned.
     * Keep the raw last-write record for sync; show the free default in that case.
     */
    val resolvedEquipment: Equipped
        get() {
            var result = equipped
            val have = owned
            for (group in Progression.Group.entries) {
                val id = result[group]
                if (id in have && Progression.item(id)?.group == group) continue
                result = result.with(group, Progression.catalog.first { it.group == group && it.isFree }.id)
            }
            return result
        }

    val spyglassesLeft: Int
        get() = purchases.count { it.item == "spyglass" } + claims.count { it.choice == Progression.SPYGLASS_PAIR } * 2 - spyglasses.size
}

/** What's been sent to the account (SyncState in Sync.swift). */
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
