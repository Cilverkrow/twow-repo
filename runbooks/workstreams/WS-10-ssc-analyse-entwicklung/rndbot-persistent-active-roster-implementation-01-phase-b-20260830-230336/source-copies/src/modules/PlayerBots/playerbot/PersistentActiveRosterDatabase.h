#pragma once

#include "PersistentActiveRoster.h"

namespace ai
{
namespace roster
{
class CharacterDatabaseStore final : public Store
{
public:
    bool LoadCurrent(Snapshot& snapshot, bool& found, std::string& error) override;
    bool LoadVersion(uint64_t versionId, Snapshot& snapshot, bool& found, std::string& error) override;
    bool FindOperation(std::string const& operationId, OperationRecord& record, bool& found, std::string& error) override;
    bool Commit(AdminRequest const& request, std::string const& canonicalRequest, Sha256 const& requestSha256,
        Snapshot const& before, bool hasBefore, Snapshot const& after, std::string const& resultCode,
        std::string& error) override;

private:
    bool LoadMembers(Snapshot& snapshot, std::string& error);
};
}
}
