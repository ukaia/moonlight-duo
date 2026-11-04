# Third-party notices

Moonlight Duo is a modified version of Moonlight for iOS. It contains work by the projects
below. Each is used under its own license.

## Moonlight for iOS: GPL-3.0

<https://github.com/moonlight-stream/moonlight-ios> by the Moonlight Game Streaming Project.
Moonlight Duo is built on its master branch as of commit `02dc978` (version 9.0.2), and keeps
its streaming, pairing, input and video decoding code. Moonlight Duo as a whole is distributed
under the same license, GPL-3.0 (see [LICENSE.txt](LICENSE.txt)). The Moonlight name and
artwork belong to their owners. This project is not affiliated with or endorsed by the
Moonlight Game Streaming Project.

## moonlight-common-c: GPL-3.0

<https://github.com/moonlight-stream/moonlight-common-c>, the shared streaming protocol core
(git submodule). It bundles:

- ENet, MIT License, Copyright (c) 2002-2020 Lee Salzman
- nanors, MIT License, Copyright (c) 2021 Joseph Calderon

Their full license texts are in the submodule.

## Libraries bundled by Moonlight for iOS

These are the prebuilt libraries in `libs/`. Each is distributed under its own license:

- FFmpeg (LGPL-2.1 or later): <https://ffmpeg.org>
- SDL2 (zlib License): <https://libsdl.org>
- Opus (BSD 3-Clause): <https://opus-codec.org>
- OpenSSL (Apache-2.0), built with <https://github.com/x2on/OpenSSL-for-iPhone>

Upstream's build notes are in [libs/Build.txt](libs/Build.txt) and
[libs/Build-OpenSSL.txt](libs/Build-OpenSSL.txt).

## X1Kit: MIT

<https://github.com/cgutman/X1Kit> (git submodule), used for Citrix X1 mouse support.

```
MIT License

Copyright (c) 2019 Adrian Carpenter

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## nxnative: MIT

<https://github.com/seedds/nxnative> by seedds. Moonlight Duo's touch gamepad
(`Limelight/Modern/MLTouchGamepad.h/.m`) is a port of nxnative's virtual gamepad
(`dm/ios/Sources/DmGamepad.m`). Its layouts, shapes, sizing constants, touch ownership rules
and stick behaviour come from that file. nxnative credits
[d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile) (MIT) as the origin of its generic
iOS parts.

```
MIT License

Copyright (c) 2026 seedds

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Hosts

Moonlight Duo streams from any host that supports the Moonlight protocol, for example
[Sunshine](https://github.com/LizardByte/Sunshine) by LizardByte and
[Wolf](https://github.com/games-on-whales/wolf) by Games on Whales. None of their code is
included in this app.
