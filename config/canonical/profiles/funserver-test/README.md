# Funserver test profile

This optional, versioned profile is selected only with
`CONFIG_PROFILE=funserver-test`. It is a configuration input for a future
authorized Docker image/runtime test, not a runtime deployment action.

It applies only the separately authorized XP and talent test rates and extends
the existing random-bot cheat set from `repair,breath,item` to
`repair,breath,item,taxi`. It neither adds a taxi mechanic nor changes bot
roster, bags, database state, loot tables, or deployment scripts.
`Rate.XP.Explore` is deliberately absent, so its canonical value is preserved.

Loot-quality multipliers are deliberately absent too. They change only some
per-row chance rolls, not grouped selection, item-count rolls, boss/rare
classification, or duplicate suppression; they cannot promise a four-item
boss/rare result or an observed epic-to-blue ratio. Any loot experiment needs
its own reviewed Core feature and deterministic fixture or Monte-Carlo gate.

All four deviations are classified in `semantic-profile.tsv`. `Rate.Talent = 2`
is an experimental global Player value; issue #226 remains the fine-tuning and
runtime-validation tracker.
