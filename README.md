# create-repistoriryy
claude test

## Mining rewards

Every rock hit that does damage shakes the screen and gives a random 0-100 Stars.
The Stars show up as an invisible drop with a yellow trail. It pops out of the rock,
falls until it lands on collidable ground, then flies into you.

| File | Where it goes in Studio |
| --- | --- |
| `src/client/Controllers/MineRewardController.luau` | New ModuleScript, same folder as `MiningController` |
| `src/client/Controllers/MiningController.luau` | 3 added lines (the require, `MineRewardController.OnHit(Rock)` in `Hit`, `MineRewardController.Start()` in `Start`) |
| `src/server/ShopServer.server.luau` | `MINE_REWARD_*` settings at the top + the `MINING REWARDS` section |

`ScreenShake` must be in `ReplicatedStorage` or `ReplicatedStorage.Modules`. It is not changed.
