# music player 

A simple vulkan-based **DEMO** music player written in zig. The project is only for the purposes of learning and is not intended for real use in it's current state.

The project ships with an example library and is hardcoded to use that.

## Dependencies

- zig (master)
- glfw
- libmad
- vulkan

## Running

```sh
git clone --recurse-submodules https://github.com/kdchambers/music_player
cd music_player
zig build run -Drelease-safe
```
## Screenshot

![alt text](assets/screenshots/active_track_mini_cropped.png?raw=true)