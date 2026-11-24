package com.mikecann.walkies.model

/**
 * Where a walk is in its life (WalkStage.swift). Every move between stages goes through
 * [after], and shared/fixtures/walk-stages.json lists the same moves for both platforms.
 * docs/walk-lifecycle.md has the diagram and why each stage exists.
 */
enum class WalkStage(val rawValue: String) {
    /**
     * Always on has seen you set off, but you're not far enough from the start for it
     * to count. It uncovers nothing yet, and is dropped if it ends like this.
     */
    Tentative("tentative"),
    /** Recording, and uncovering tiles on the map (not yet in saved places). */
    Walking("walking"),
    /** Closed: route, end and tile credit are in the walk's own file. Its credit may not be in the saved places yet. */
    Sealed("sealed"),
    /** Its credit is in the saved places too. Nothing more happens to it apart from steps arriving late. */
    Done("done");

    enum class Event(val rawValue: String) {
        /** Far enough from where a tentative walk started. */
        Confirmed("confirmed"),
        /**
         * A gap, a quiet spell, a ride somewhere else, End walk, or always on turned off,
         * and the walk counts (or you pressed End).
         */
        Ended("ended"),
        /** A tentative walk that ended without counting. Its file goes. */
        Dropped("dropped"),
        /** Its credit was saved into places. */
        Committed("committed"),
    }

    /**
     * The stage after [event], or null when that move isn't allowed and the event must
     * be ignored. Dropping is allowed from [Tentative] and leaves no stage.
     */
    fun after(event: Event): WalkStage? = when {
        this == Tentative && event == Event.Confirmed -> Walking
        (this == Tentative || this == Walking) && event == Event.Ended -> Sealed
        this == Sealed && event == Event.Committed -> Done
        else -> null
    }

    fun allows(event: Event): Boolean = after(event) != null || (this == Tentative && event == Event.Dropped)

    /** Still recording. */
    val isOpen: Boolean get() = this == Tentative || this == Walking
}
