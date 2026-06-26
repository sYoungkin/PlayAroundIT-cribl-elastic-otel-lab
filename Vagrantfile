ENV["VAGRANT_DEFAULT_PROVIDER"] = "vmware_desktop"
Vagrant.require_version ">= 2.3.0"

BOX_IMAGE = "generic/ubuntu2204"
ELASTIC = 1
KIBANA  = 1
CRIBL   = 1
APP     = 1

# --- Build /etc/hosts entries from the node counts ------------------
# Single source of truth: the counts above drive both the VMs and the
# hosts file, so they can never drift apart. Node names only - these
# match the cert SANs, so full TLS verification passes when connecting
# by node name. (Service names live in the cert SANs as a future option
# for a VIP/load balancer, but are intentionally not in /etc/hosts.)
def build_hosts_entries(elastic, kibana, cribl, app)
  entries = []
  (1..elastic).each { |i| entries << "192.168.65.1#{i} elastic-#{i}" }
  (1..kibana).each  { |i| entries << "192.168.65.2#{i} kibana-#{i}"  }
  (1..cribl).each   { |i| entries << "192.168.65.3#{i} cribl-#{i}"   }
  (1..app).each     { |i| entries << "192.168.65.4#{i} app-#{i}"     }
  entries.join("\n")
end

HOSTS_ENTRIES = build_hosts_entries(ELASTIC, KIBANA, CRIBL, APP)

Vagrant.configure("2") do |config|
  config.vagrant.plugins = ["vagrant-vmware-desktop"]
  config.vm.box = BOX_IMAGE

  config.vm.provider "vmware_desktop" do |v|
    v.cpus   = 1
    v.memory = 1024
  end

  config.vm.synced_folder ".", "/vagrant", disabled: true

  # --- Global: inject node-name -> IP resolution into every node ------
  # Runs before per-node provisioners, so name resolution is in place
  # before any install script runs. Idempotent via the grep guard.
  config.vm.provision "shell", inline: <<~SHELL
    grep -q "LAB-HOSTS-BLOCK" /etc/hosts || cat >> /etc/hosts <<'HOSTS'

    # LAB-HOSTS-BLOCK (generated - do not edit)
    #{HOSTS_ENTRIES}
    HOSTS
  SHELL

  # --- Elasticsearch nodes --------------------------------------------
  (1..ELASTIC).each do |i|
    config.vm.define "elastic-#{i}" do |subconfig|
      subconfig.vm.hostname = "elastic-#{i}"
      subconfig.vm.network "private_network", ip: "192.168.65.1#{i}"

      subconfig.vm.provision "file",
        source: "certs/ca.crt", destination: "/tmp/ca.crt"
      subconfig.vm.provision "file",
        source: "certs/elasticsearch-chain.crt", destination: "/tmp/elasticsearch-chain.crt"
      subconfig.vm.provision "file",
        source: "certs/elasticsearch.key", destination: "/tmp/elasticsearch.key"

      subconfig.vm.provision "shell",
        path: "scripts/elasticsearch.sh",
        env: { "ADMIN_PWD" => "adminuser123!" }
    end
  end

  # --- Kibana nodes ---------------------------------------------------
  (1..KIBANA).each do |i|
    config.vm.define "kibana-#{i}" do |subconfig|
      subconfig.vm.hostname = "kibana-#{i}"
      subconfig.vm.network "private_network", ip: "192.168.65.2#{i}"

      subconfig.vm.provider "vmware_desktop" do |v|
        v.cpus   = 2
        v.memory = 4096
      end

      subconfig.vm.provision "file",
        source: "certs/ca.crt", destination: "/tmp/ca.crt"
      subconfig.vm.provision "file",
        source: "certs/kibana-chain.crt", destination: "/tmp/kibana-chain.crt"
      subconfig.vm.provision "file",
        source: "certs/kibana.key", destination: "/tmp/kibana.key"

      subconfig.vm.provision "shell",
        path: "scripts/kibana.sh",
        env: { "ADMIN_PWD" => "adminuser123!" }
    end
  end

  # --- Cribl nodes ----------------------------------------------------
  (1..CRIBL).each do |i|
    config.vm.define "cribl-#{i}" do |subconfig|
      subconfig.vm.hostname = "cribl-#{i}"
      subconfig.vm.network "private_network", ip: "192.168.65.3#{i}"

      subconfig.vm.provision "file",
        source: "packages/cribl-4.18.2-fd1f0d2f-linux-x64.tgz",
        destination: "/tmp/cribl.tgz"
      subconfig.vm.provision "file",
        source: "certs/ca.crt", destination: "/tmp/ca.crt"
      subconfig.vm.provision "file",
        source: "certs/cribl-chain.crt", destination: "/tmp/cribl-chain.crt"
      subconfig.vm.provision "file",
        source: "certs/cribl.key", destination: "/tmp/cribl.key"

      subconfig.vm.provision "shell",
        path: "scripts/cribl.sh"
    end
  end

  # --- App-server nodes -----------------------------------------------
  (1..APP).each do |i|
    config.vm.define "app-#{i}" do |subconfig|
      subconfig.vm.hostname = "app-#{i}"
      subconfig.vm.network "private_network", ip: "192.168.65.4#{i}"
      subconfig.vm.provision "file",
        source: "certs/ca.crt", destination: "/tmp/ca.crt"
      subconfig.vm.provision "shell",
        path: "scripts/app-server.sh"
    end
  end
end