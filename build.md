
install

```
python3 -m venv $HOME/vcs_colcon_installation
. $HOME/vcs_colcon_installation/bin/activate
pip3 install vcstool colcon-common-extensions
```

build

vcs import src < repos.yaml

```
source $HOME/vcs_colcon_installation/bin/activate
colcon build
```