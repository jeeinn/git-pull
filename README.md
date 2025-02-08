# git-pull

Update all Git projects and local branches in the specified directory

更新指定目录下所有的git项目和项目中的本地分支

## 使用
默认更新当前目录下所有的一级 git 项目，可以通过一个参数指定要更新的目录

```bash
git-pull.sh <directory>
```
## 说明
考虑到Python项目的通用性还是不够高 https://github.com/jeeinn/git_multi_repo_updater

所以使用 bash 脚本重新编写了逻辑

## 功能增强
1. 添加了自动拉取分支时通过使用 stash 来最大程度避免冲突
2. 当有冲突存在时会提醒手动解决