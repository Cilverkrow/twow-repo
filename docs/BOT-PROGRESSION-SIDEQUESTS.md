# Bot progression sidequests

## Status and purpose

This is a product-discovery backlog for the Windows-first delivery path. It
records ideas worth preserving while the core operational baseline is built. It
is **not** an ADR, implementation approval, live-server authorization, or a
promise that every item will be built.

Each item needs a bounded data-discovery task and an explicit product decision
before code, migration, configuration, or live changes are proposed.

## 1. Talent roles and accelerated bot progression

### Intended player experience

Bots should visibly grow into useful, varied group roles quickly enough that
repeated dungeon and raid runs feel rewarding. A stable 50-bot roster should
include tanks, healers, melee DPS, and ranged DPS rather than mechanically
identical builds.

### Candidate policy

- Assign each bot a group role and a weighted preferred talent tree.
- Let the preferred tree guide most talent choices while permitting selected
  off-tree utility talents.
- Evaluate a bot-only accelerated talent budget, including the proposed
  two-times normal talent-point allowance, as a deliberate non-competitive
  progression mode rather than as accidental over-leveling.
- Prefer deterministic, valid allocation paths over random choices that can
  strand points behind prerequisites.

### Required discovery and decision gates

- Extract the actual Turtle client/server talent, rank, prerequisite, and spell
  IDs; do not reuse an assumed upstream 1.12 mapping.
- Inspect the existing PlayerBot talent allocator and configuration to establish
  whether it is data-driven, hard-coded, valid for the current client, and safe
  above the normal point budget.
- Decide the maximum bot-only point budget, permitted off-tree share, respec
  policy, and whether player characters remain strictly normal.
- Prove that the client, Core, talents, trainers, and PlayerBot logic tolerate
  the selected budget without invalid builds or crashes.

## 2. Profession ecology and self-supply

### Intended player experience

Bots should form a balanced crafting population. Their professions should
support equipment, consumables, gathering, trading, and later role-play rather
than produce an accidental surplus of one craft and an absence of another.

### Candidate policy

- Keep the accepted two-primary-profession bot cap as the starting constraint.
- Use class, race, role, and verified racial profession bonuses as weights, not
  as unconditional rules.
- Allocate against global quotas for the whole active roster before making
  individual weighted choices.
- Keep First Aid universal; retain the separately proposed, bounded shares for
  Cooking, Fishing, and Survival.
- Preserve existing bot identities when a roster is reduced: inactive bots keep
  their profession history for a later return.

### Required discovery and decision gates

- Read the actual Turtle profession IDs, available professions, skill caps,
  recipes, and racial bonuses. In particular, do not assume High Elf behavior
  from Blood Elf data.
- Repair and re-measure the existing factory allocation defect before treating
  the current empty distribution as a policy result.
- Define target quotas and legal pair pools, then test factory refresh so it
  does not remove provisioned skills.
- Decide how gathering, crafting, inventory ownership, auction/trade, and
  bot-to-bot transfers are authorized before attempting an autonomous economy.

## 3. Fast PvE rewards without an uncontrolled economy

### Intended player experience

Repeated dungeon and raid content should equip a player-and-bot group in a few
enjoyable clears, not require dozens of identical runs. Bot progression should
be visible alongside player progression.

### Candidate policy

- Evaluate a boss- and explicitly listed rare-mob-only reward multiplier,
  initially in a controlled test range such as 3x to 5x.
- Treat "more successful item rolls" and "every entry in a loot table drops" as
  different proposals. The latter is far more disruptive and is not implied by
  the former.
- Exclude or separately classify quests, keys, tokens, unique progression
  items, currency, and items whose duplication changes encounter access.

### Required discovery and decision gates

- Inventory the current loot pipeline and verify how chance, group loot,
  unique items, stack limits, binding, and raid distribution behave.
- Define the exact eligible creature list and the multiplier semantics.
- Measure bot gearing, storage, trade, gold, and faction-PvP consequences in a
  disposable/test setting before any Windows live change.
- Provide a forward/reverse migration or configuration rollback path.

## 4. Guild, group, PvP, and world-event ecology

### Intended player experience

More than one bot guild should form groups, improve their equipment, appear in
the world, and occasionally create social goals: dungeon groups, raids,
Battlegrounds, Tarren Mill activity, and guild events.

### Constraints

- PvE acceleration must not create one faction with an overwhelming gear or
  population advantage in PvP.
- Group construction must deliberately reserve tanks, healers, and damage roles
  instead of relying on random availability.
- Guild/event scheduling is a deterministic game-system responsibility. An LLM
  may phrase invitations or flavour text, but does not receive authority to
  mutate guild, group, inventory, or PvP state directly.

### Required discovery and decision gates

- Inventory existing PlayerBot support for guilds, groups, queues, battlegrounds,
  raids, equipment, and event scheduling.
- Establish faction-balanced population and equipment metrics before enabling
  any automated PvP or guild-event behavior.
- Define per-event safety limits, opt-in/opt-out behavior, and a clean disable
  path.

## 5. Profiles, memory, language, and cooperative crafting

### Intended player experience

A bot can speak consistently about its race, class, profession, recent
adventures, and practical needs. For example, a crafter can ask for materials,
another bot can offer a recipe, and the group can choose to gather together.

### Candidate policy

- Use versioned, durable bot profiles and compact structured memory events, not
  unbounded free-text files or raw chat transcripts.
- Supply only relevant facts, a bounded memory summary, and the accepted maximum
  number of traits to an LLM request.
- Keep English as the in-game language.
- Let the LLM propose conversational intent only. Follow, gather, trade, craft,
  equip, and group changes require deterministic capability checks and explicit
  server-side execution.

### Required discovery and decision gates

- Complete the persistent roster before binding durable personality or memory
  to bot identity.
- Verify available database views and safe game capabilities for inventory,
  recipes, professions, groups, quests, guilds, and chat.
- Preserve the ADR-0012/0013 failure boundary: no database credentials for the
  bridge or Ollama, no direct LLM authority, and no impact on ordinary bot play
  when inference is unavailable.

## Proposed order of consideration

1. Windows operational baseline and persistent 50-bot roster.
2. Talent-data discovery and bot role model.
3. Profession-data discovery, allocation repair, and quota model.
4. Controlled PvE reward/loot experiment.
5. Guild/group/PvP capability inventory and balance design.
6. Optional Ollama language layer and structured memory.
7. Only after the prior capabilities are proven: cooperative gathering, crafting,
   trading, and event behavior.

## 6. Player AddOns and possible bot-facing adapters

### Boundary

WoW AddOns execute in a human player's client UI. Server-side PlayerBots do not
run a WoW client, do not load Lua AddOns, and must not be represented as though
they do. Installing a third-party AddOn therefore improves the player
experience; it does not grant a bot quest tracking, boss timers, TurtleRP
profile, or game authority.

Any later bot-facing display is a separate, narrow server-to-client adapter. It
must expose approved profile facts or encounter state as value data, not allow a
client AddOn or an LLM to control bot, group, guild, inventory, trade, or
database state.

### Candidate client AddOn shortlist

| Candidate | Intended player value | Decision status |
| --- | --- | --- |
| pfQuest + pfQuest-turtle | Quest, world-object, item, and Turtle-specific database/map context | Evaluate together as one version-pinned client stack |
| ImmersiveDialogUI | Player-side quest/gossip presentation | Evaluate as a cosmetic UI option; no bot integration implied |
| TurtleRP | Visible player RP profiles and profile communication | Evaluate for normal player RP first; investigate its message/profile protocol only as future adapter evidence |
| BigWigs | Player-side encounter alerts and timers | Evaluate for raid usability; use encounter modules only as a reference when designing deterministic bot tactics |
| Atlas-CFM | Dungeon maps, loot-panel, and quest browsing | Evaluate as a player reference tool |
| ShaguDPS | Lightweight player-visible combat measurement | Evaluate as an observational tool, not bot control |
| pfUI-turtle | Broad UI replacement | Choose deliberately against a default-UI-plus-tweaks stack; do not install overlapping UI frameworks indiscriminately |
| ShaguTweaks + extras | Selected default-UI enhancements | Evaluate individual modules only, after choosing the UI stack |
| ActionButtonUtils | Action-button visual feedback | Low-priority cosmetic option; listed once despite duplicate discovery input |

### Future adapter experiments

- **TurtleRP-like bot profiles:** a project-owned companion adapter could render
  approved bot name, description, profession, and limited at-a-glance traits in
  the player's UI. It must not impersonate an installed TurtleRP client on a
  bot, scrape private profile data, or create a hidden command channel.
- **Encounter assistance:** BigWigs remains an aid for the human player. Bot
  responses to boss phases belong in deterministic server-side tactics, with
  encounter modules usable only as a researched reference and subject to their
  license/provenance.
- **Quest/profession context:** player UI data can improve what the player sees;
  bot pathing and gathering must rely on independently validated server/client
  world data, not on a player's local AddOn database.

### Required intake gate before client installation or distribution

For every selected AddOn, record source URL, exact commit/release, license,
SHA-256 of the downloaded archive, target client version, folder name, required
dependencies, default modules, saved-variable behavior, memory/load impact, and
an enable/disable test on the Windows client. Keep third-party AddOn sources and
archives out of the server-source repository unless a later licensing and
provenance decision explicitly permits vendoring.
