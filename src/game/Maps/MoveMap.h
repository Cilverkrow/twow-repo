/*
 * Copyright (C) 2005-2011 MaNGOS <http://getmangos.com/>
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

#ifndef _MOVE_MAP_H
#define _MOVE_MAP_H

#include "Platform/CompilerDefs.h"
#include "Platform/Define.h"
#include <unordered_map>

#include "Detour/Include/DetourAlloc.h"
#include "Detour/Include/DetourNavMesh.h"
#include "Detour/Include/DetourNavMeshQuery.h"

#include <thread>
#include <shared_mutex>

//  memory management
inline void* dtCustomAlloc(size_t size, dtAllocHint /*hint*/)
{
    return (void*)new unsigned char[size];
}

inline void dtCustomFree(void* ptr)
{
    delete [] (unsigned char*)ptr;
}

//  move map related classes
namespace MMAP
{
    typedef std::unordered_map<uint32, dtTileRef> MMapTileSet;
    typedef std::unordered_map<std::thread::id, dtNavMeshQuery*> NavMeshQuerySet;

    // dummy struct to hold map's mmap data
    struct MMapData
    {
        MMapData(dtNavMesh* mesh) : navMesh(mesh) {}
        ~MMapData()
        {
            for (const auto& itr : navMeshQueries)
                dtFreeNavMeshQuery(itr.second);

            if (navMesh)
                dtFreeNavMesh(navMesh);
        }

        dtNavMesh* navMesh;

        // we have to use single dtNavMeshQuery for every instance, since those are not thread safe
        NavMeshQuerySet navMeshQueries; // threadId to query
        std::shared_mutex navMeshQueries_lock;
        MMapTileSet mmapLoadedTiles; // maps [map grid coords] to [dtTile]
        std::mutex tilesLoading_lock;

        // Schuetzt das dtNavMesh selbst. Geteilt, solange eine Abfrage
        // darueber laeuft, ausschliesslich beim Hinzufuegen und Entfernen
        // von Kacheln. Ohne das entfernt TerrainInfo::CleanUpGrids eine
        // Kachel unter einem laufenden findPath weg.
        std::shared_mutex navMesh_lock;
    };

    typedef std::unordered_map<uint32, MMapData*> MMapDataSet;

    // Haelt das Leseschloss einer Karte, solange er lebt. Ein Nullzeiger
    // ist zulaessig und bedeutet: fuer diese Karte gibt es kein Navmesh,
    // dann ist auch nichts zu schuetzen.
    class NavMeshReadGuard
    {
        public:
            explicit NavMeshReadGuard(std::shared_mutex* mutex) : m_mutex(mutex)
            {
                if (m_mutex)
                    m_mutex->lock_shared();
            }

            ~NavMeshReadGuard()
            {
                if (m_mutex)
                    m_mutex->unlock_shared();
            }

            NavMeshReadGuard(NavMeshReadGuard const&) = delete;
            NavMeshReadGuard& operator=(NavMeshReadGuard const&) = delete;

        private:
            std::shared_mutex* m_mutex;
    };

    // singelton class
    // holds all all access to mmap loading unloading and meshes
    class MMapManager
    {
        public:
            MMapManager() : loadedTiles(0) {}
            ~MMapManager();

            bool loadMap(uint32 mapId, int32 x, int32 y);
            // bot's 4-arg forms.
            bool loadMap(uint32 mapId, int32 x, int32 y, uint32 /*instanceId*/) { return loadMap(mapId, x, y); }
            bool loadMap(std::string const& /*dataPath*/, uint32 mapId, int32 x, int32 y) { return loadMap(mapId, x, y); }
            bool loadGameObject(uint32 displayId);
            bool unloadMap(uint32 mapId, int32 x, int32 y);
            bool unloadMap(uint32 mapId);
            // bot calls these with various arg counts.
            // Stubs that ignore extra args.
            template<typename... A> bool loadAllMapTiles(A... /*args*/) { return false; }
            template<typename... A> bool loadMapInstance(A... /*args*/) { return false; }
            template<typename... A> bool IsMMapIsLoaded(A... /*args*/) const { return true; }
            template<typename... A> bool loadMapAlt(A... /*args*/) { return false; }
            bool unloadMapInstance(uint32 mapId, std::thread::id instanceId);

            // The returned [dtNavMeshQuery const*] is NOT threadsafe
            // Returns a NavMeshQuery valid for current thread only.
            dtNavMeshQuery const* GetNavMeshQuery(uint32 mapId);
            // bot's 2-arg form (instanceId ignored).
            dtNavMeshQuery const* GetNavMeshQuery(uint32 mapId, uint32 /*instanceId*/) { return GetNavMeshQuery(mapId); }
            dtNavMeshQuery const* GetModelNavMeshQuery(uint32 displayId);
            dtNavMesh const* GetNavMesh(uint32 mapId);

            // Das Schloss zu einer Karte. Muss ueber die gesamte Dauer der
            // Abfrage gehalten werden, nicht nur beim Holen der Abfrage -
            // die Polygonzeiger zeigen ins Netz und werden ungueltig,
            // sobald eine Kachel verschwindet.
            std::shared_mutex* GetNavMeshLock(uint32 mapId);
            std::shared_mutex* GetModelNavMeshLock(uint32 displayId);

            uint32 getLoadedTilesCount() const { return loadedTiles; }
            uint32 getLoadedMapsCount() const { return loadedMMaps.size(); }
        private:
            bool loadMapData(uint32 mapId);
            static uint32 packTileID(int32 x, int32 y);

            MMapDataSet loadedMMaps;
            std::shared_mutex loadedMMaps_lock;
            MMapDataSet loadedModels;

            uint32 loadedTiles;
            std::mutex lockForModels;
    };

    // static class
    // holds all mmap global data
    // access point to MMapManager singelton
    class MMapFactory
    {
        public:
            static MMapManager* createOrGetMMapManager();
            static void clear();
    };
}

#endif  // _MOVE_MAP_H
