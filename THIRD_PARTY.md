# Third-party software and provenance

Flameshoter is a GPL-3.0-or-later derivative of [Flameshot](https://github.com/flameshot-org/flameshot), initially based on commit `da34dcb1b296bd2e3bc589767abbe788084215ae`. Copyright and SPDX notices in upstream files are preserved. The three flame vector paths in the Icon Composer document are derived from Flameshot's `data/img/app/org.flameshot.Flameshot.svg` under the same project license. Apple Icon Composer and Apple's asset compiler render the icon materials; the generated-image experiment is not used in the application.

The release source is available at https://github.com/Word2VecT/flameshoter, including its build scripts and dependency revisions.

| Component | Version / revision | License | Source |
| --- | --- | --- | --- |
| Qt | 6.12.0 | LGPL-3.0 / GPL-3.0, as applicable | https://download.qt.io/official_releases/qt/6.12/6.12.0/submodules/ |
| Qt Color Widgets | 5d52e907e50dc88cf969b41cea44665ff6c475b1 | LGPL-3.0 | https://gitlab.com/mattbas/Qt-Color-Widgets |
| KDSingleApplication | 1.2.1 | MIT | https://github.com/KDAB/KDSingleApplication |
| QHotkey | d7063877c14d5ae2b489dc70bbe02e76a43bf38b | BSD-3-Clause | https://github.com/flameshot-org/QHotkey |

Qt is dynamically linked. The other components are built from the pinned source revisions declared in CMakeLists.txt. License texts are included in `LICENSE` and `licenses/`, and copied into release bundles. Build from the public source with replacement libraries using the documented CMake workflow.

Apple frameworks and SF Symbols remain governed by Apple's terms. Icon Composer itself is a build/design tool and is not redistributed with the application.
