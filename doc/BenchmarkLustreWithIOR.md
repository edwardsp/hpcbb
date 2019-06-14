# Benchmark Lustre with IOR

This document describes the process to build and test a simple Lustre setup.

Make sure that `hpcbb` is checked out and "installed":

    git clone https://github.com/edwardsp/hpcbb.git

Run the "install" which just creates the bin directory in place and sets your `PATH` environment variable.

Now create a working directory for your cluster.  This can be anywhere and not inside the hpcbb repo!

Copy the `examples/simple_lustre.json` to this directory (Note: if you call it `config.json` you don't need to use the `-c` option for the `hpcbb-*` commands).

Now, edit the config file and set the `resource_group` and `location` variables. Now build the lustre setup:

    hpcbb-build 2>&1 | tee build.log

Let's connect to the cluster

    hpcbb-connect headnode

Now to install relevant packages and build IOR:

    sudo yum install -y mpich-devel git automake
    cd /lustre
    git clone https://github.com/LLNL/ior.git
    cd ior
    ./bootstrap
    MPICC=/usr/lib64/mpich/bin/mpicc ./configure
    make
    cp src/ior /lustre/ior.exe

The `mpich` package is also required on and nodes running IOR.

    WCOLL=~/hpcbb_install/hostlists/nodes pdsh sudo yum install -y mpich

Now we can run:

    cd /lustre
    /usr/lib64/mpich/bin/mpirun -np 8 -hostfile ~/hpcbb_install/hostlists/nodes /lustre/ior.exe -a POSIX     -v -B -e -F -r -w -t 32m -b 4G     -o /lustre/test.`date +"%Y-%m-%d_%H-%M-%S"`

