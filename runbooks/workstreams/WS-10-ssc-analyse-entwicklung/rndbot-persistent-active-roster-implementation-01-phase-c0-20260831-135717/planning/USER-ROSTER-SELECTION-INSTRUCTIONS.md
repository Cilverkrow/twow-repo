# Required explicit 50-GUID selection

The dated active set is empty, so no automatic proposal is lawful.

Select exactly 50 distinct `character_guid` values from `evidence/ROSTER-CANDIDATES.tsv`, where every selected row must retain `base_eligible=1`. The smaller `evidence/EXPIRED-ADD-CANDIDATES.tsv` contains 86 eligible characters that had historical add leases; it is a convenient review subset but is not ranked and no first-50 rule applies.

Return the 50 GUIDs explicitly. C0 will then:

1. match every GUID byte-for-byte to the dated candidate inventory;
2. reject duplicates, missing rows or any eligibility mismatch;
3. sort the approved set numerically by Character GUID;
4. serialize and hash the ordered 50-member snapshot;
5. create one new canonical lowercase UUIDv4;
6. prepare—but not apply—the canonical INITIALIZE request;
7. report both uppercase SHA-256 values for separate approval.

This selection authorizes neither migration nor deployment. Phase C remains blocked.
