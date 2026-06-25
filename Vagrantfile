ENV["VAGRANT_DEFAULT_PROVIDER"] = "vmware_desktop"
Vagrant.require_version ">= 2.3.0"
BOX_IMAGE = "generic/ubuntu2204"

ELASTIC = 1
KIBANA  = 1
CRIBL   = 1
APP   = 0

Vagrant.configure("2") do |config|
  config.vagrant.plugins = ["vagrant-vmware-desktop"]
  config.vm.box = BOX_IMAGE
  config.vm.provider "vmware_desktop" do |v|
    v.cpus   = 1
    v.memory = 1024
  end
  config.vm.synced_folder ".", "/vagrant", disabled: true


  # Elasticsearch nodes
  (1..ELASTIC).each do |i|
    config.vm.define "elastic-#{i}" do |subconfig|
      subconfig.vm.hostname = "elastic-#{i}"

      subconfig.vm.provision "file",
        source: "certs/ca.crt", destination: "/tmp/ca.crt"
      subconfig.vm.provision "file",
        source: "certs/elasticsearch.crt", destination: "/tmp/elasticsearch.crt"
      subconfig.vm.provision "file",
        source: "certs/elasticsearch.key", destination: "/tmp/elasticsearch.key"

      subconfig.vm.provision "shell",
        path: "scripts/elasticsearch.sh",
        env: { "ADMIN_PWD" => "adminuser123!" }
    end
  end

  # Kibana nodes
  (1..KIBANA).each do |i|
    config.vm.define "kibana-#{i}" do |subconfig|
      subconfig.vm.hostname = "kibana-#{i}"

      subconfig.vm.provider "vmware_desktop" do |v|
        v.cpus   = 2
        v.memory = 4096
      end

      subconfig.vm.provision "file",
        source: "certs/ca.crt", destination: "/tmp/ca.crt"
      subconfig.vm.provision "file",
        source: "certs/kibana.crt", destination: "/tmp/kibana.crt"
      subconfig.vm.provision "file",
        source: "certs/kibana.key", destination: "/tmp/kibana.key"

      subconfig.vm.provision "shell",
        path: "scripts/kibana.sh",
        env: { "ADMIN_PWD" => "adminuser123!" }
    end
  end

  # Cribl nodes
  (1..CRIBL).each do |i|
    config.vm.define "cribl-#{i}" do |subconfig|
      subconfig.vm.hostname = "cribl-#{i}"

      subconfig.vm.provision "file",
        source: "packages/cribl-4.18.2-fd1f0d2f-linux-x64.tgz",
        destination: "/tmp/cribl.tgz"
      subconfig.vm.provision "file",
        source: "certs/ca.crt", destination: "/tmp/ca.crt"
      subconfig.vm.provision "file",
        source: "certs/cribl.crt", destination: "/tmp/cribl.crt"
      subconfig.vm.provision "file",
        source: "certs/cribl.key", destination: "/tmp/cribl.key"

      subconfig.vm.provision "shell",
        path: "scripts/cribl.sh"
    end
  end

  # App-server nodes
  (1..APP).each do |i|
    config.vm.define "app-#{i}" do |subconfig|
      subconfig.vm.hostname = "app-#{i}"
      subconfig.vm.provision "shell",
        path: "scripts/app-server.sh"
    end
  end

end