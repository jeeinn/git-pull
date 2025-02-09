# git-pull

Update all Git projects and local branches in the specified directory

更新指定目录下所有的 Git 项目和项目中的本地分支

## 使用
默认更新当前目录下所有的一级 Git 项目，可以通过一个参数指定要更新的目录

```bash
chmod +x git-pull.sh
./git-pull.sh <directory>
```
## 说明
考虑到 Python 项目的通用性还是不够高（https://github.com/jeeinn/git_multi_repo_updater）

比如： macOS 下使用了 tk 的兼容问题，又或者前端开发同学并没有安装 python 

所以使用 bash 脚本重新编写了逻辑，添加了自动拉取分支时通过使用 stash 来最大程度避免冲突。

* 测试情况
1. [x] Windows11 的 Git Bash 环境测试通过 `git version 2.47.1.windows.1`
2. [x] macOS Sequoia 15.3 zsh 测试通过 `git version 2.48.1` `GNU bash, version 3.2.57(1)-release (x86_64-apple-darwin24`
3. [x] Linux AliYun 测试通过 `git version 2.43.5` `GNU bash, version 4.4.20(1)-release (x86_64-koji-linux-gnu)`

## 功能增强
1. 添加了自动拉取分支时通过使用 stash 来最大程度避免冲突
2. 当有冲突存在时会提醒手动解决