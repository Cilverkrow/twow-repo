/*
 * Copyright (C) 2020-2021 Turtle WoW
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#ifndef SHOP_MGR_H
#define SHOP_MGR_H

#include "Common.h"
#include "SharedDefines.h"
#include "Platform/Define.h"
#include <mutex>

struct ShopRequest
{
    ShopRequest(uint32 acc, uint32 guid, uint32 item) : accountId(acc), guidLow(guid), itemId(item) {}
    uint32 accountId;
    uint32 guidLow;
    uint32 itemId;
};

class ShopMgr
{
    public:
        bool RequestBalance(uint32 accountId);
        bool RequestPurchase(uint32 accountId, uint32 guidLow, uint32 itemId);
        void ProcessRequestsWorker();

        // Credit an account's shop balance.
        //
        // The seam a module uses to grant coins without owning the table.
        // shop_coins belongs to the shop; a module that wrote it directly would
        // break the one-schema-one-owner rule (ADR-0021) and would have to
        // duplicate the insert-or-add shape GetBalance depends on for an
        // account that has never been in the shop.
        //
        // Asynchronous, like every other write here. Awarding zero is a no-op
        // rather than a pointless round trip.
        void AwardCoins(uint32 accountId, uint32 amount);
    private:
        int32 GetBalance(uint32 accountId);
        void BuyItem(uint32 accountId, uint32 guidLow, uint32 itemId);

        std::vector<ShopRequest> m_pendingRequests;
        std::mutex m_mutex;
};

extern ShopMgr sShopMgr;

#endif
