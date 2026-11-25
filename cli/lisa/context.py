"""What every command works with: the settings, the console, and the adapters, each made on first use."""
from functools import cached_property

from .adapters.hpc import LoginNode
from .adapters.kube import Cluster
from .adapters.processes import Processes
from .console import Console
from .settings import Settings


class Context:
    def __init__(self, settings: Settings, console: Console):
        self.settings = settings
        self.console = console
        self.say = console.say

    @cached_property
    def cluster(self) -> Cluster:
        self.settings.home.create()
        return Cluster(self.settings.kubeconfig, self.settings.home.state / "discovery.json")

    @cached_property
    def login(self) -> LoginNode:
        s = self.settings
        s.home.create()
        return LoginNode(s.hpc_login_host, s.hpc_user, s.ssh_key, s.home.known_hosts,
                         s.hpc_path("runner", "hpc.sh"))

    @cached_property
    def processes(self) -> Processes:
        self.settings.home.create()
        return Processes(self.settings.home)

    def close(self) -> None:
        if "login" in self.__dict__:
            self.login.close()
