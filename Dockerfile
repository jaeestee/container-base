# Use Ubuntu as the base
FROM ubuntu:22.04

########################################
# Configure ENV
########################################

SHELL ["/bin/bash", "-c"]

ENV SHELL=/bin/bash
ENV DEBIAN_FRONTEND=noninteractive

########################################
# Add docker-clean
########################################

ADD extras/docker-clean /usr/bin/docker-clean
RUN chmod a+rx /usr/bin/docker-clean && docker-clean

########################################g
# Necessary packages
########################################

RUN apt-get update --yes \
    && apt-get install -yq --no-install-recommends curl wget build-essential \
    && docker-clean

########################################
# Install mpi
########################################

# necessities and IB stack
RUN apt-get update && apt-get install -yq gnupg2 ca-certificates
RUN curl -k -L http://www.mellanox.com/downloads/ofed/RPM-GPG-KEY-Mellanox | apt-key add -
RUN curl -k -L https://linux.mellanox.com/public/repo/mlnx_ofed/5.0-2.1.8.0/ubuntu18.04/mellanox_mlnx_ofed.list > /etc/apt/sources.list.d/mlnx_ofed.list
RUN apt-get update \
    && apt-get install -yq --no-install-recommends gfortran bison libibverbs-dev libnuma-dev \
    libibmad-dev libibumad-dev librdmacm-dev libxml2-dev ca-certificates libfabric-dev \
    mlnx-ofed-basic ucx \
    && docker-clean

# Install PSM2
ARG PSM=PSM2
ARG PSMV=11.2.230
ARG PSMD=opa-psm2-${PSM}_${PSMV}

RUN curl -L https://github.com/intel/opa-psm2/archive/${PSM}_${PSMV}.tar.gz | tar -xzf - \
    && cd ${PSMD} \
    && make PSM_AVX=1 -j $(nproc --all 2>/dev/null || echo 2) \
    && make LIBDIR=/usr/lib/x86_64-linux-gnu install \
    && cd ../ && rm -rf ${PSMD}

# Install impi-19.0.7
ARG MAJV=19
ARG MINV=0
ARG BV=.7
ARG DIR=intel${MAJV}-${MAJV}.${MINV}${BV}

RUN curl -k -L https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS-2019.PUB | apt-key add -
RUN echo deb https://apt.repos.intel.com/mpi all main > /etc/apt/sources.list.d/intel-mpi.list
RUN apt-get update \
    && apt-get install -y intel-mpi-20${MAJV}${BV}-102 \
    && rm -r /opt/intel/compilers_and_libraries/linux/mpi/intel64/lib/debug/libmpi.a \
    /opt/intel/compilers_and_libraries/linux/mpi/intel64/lib/debug_mt/libmpi.a \
    /opt/intel/compilers_and_libraries/linux/mpi/intel64/lib/release_mt/libmpi.a \
    && docker-clean

# Configure environment for impi
ENV MPIVARS_SCRIPT=/opt/intel/compilers_and_libraries/linux/mpi/intel64/bin/mpivars.sh \
    I_MPI_LIBRARY_KIND=release \
    I_MPI_OFI_LIBRARY_INTERNAL=1 \
    I_MPI_REMOVED_VAR_WARNING=0 \
    I_MPI_VAR_CHECK_SPELLING=0 \
    BASH_ENV=/opt/intel/compilers_and_libraries/linux/mpi/intel64/bin/mpivars.sh
RUN sed -i 's~bin/sh~bin/bash~' $MPIVARS_SCRIPT \
    && sed -i '/bin\/bash/a \[ "${IMPI_LOADED}" == "1" \] && return' $MPIVARS_SCRIPT \
    && echo "export IMPI_LOADED=1" >> $MPIVARS_SCRIPT \
    && echo -e '#!/bin/bash\n. /opt/intel/compilers_and_libraries/linux/mpi/intel64/bin/mpivars.sh -ofi_internal=1 release\nexec "${@}"' > /entry.sh \
    && chmod +x /entry.sh

# Add hello world
ADD extras/hello.c /tmp/hello.c
RUN mpicc /tmp/hello.c -o /usr/local/bin/hellow \
    && rm /tmp/hello.c \
    && docker-clean

# Build benchmark programs
ADD extras/install_benchmarks.sh /tmp/install_benchmarks.sh
RUN bash /tmp/install_benchmarks.sh

########################################
# Install JupyterLab
########################################

RUN apt-get update --yes && \
    apt-get install -yq --no-install-recommends \
    # - bzip2 is necessary to extract the micromamba executable.
    bzip2 \
    ca-certificates \
    fonts-liberation \
    locales \
    # - pandoc is used to convert notebooks to html files
    #   it's not present in arm64 ubuntu image, so we install it here
    pandoc \
    # - run-one - a wrapper script that runs no more
    #   than one unique  instance  of  some  command with a unique set of arguments,
    #   we use `run-one-constantly` to support `RESTARTABLE` option
    run-one \
    sudo \
    # - tini is installed as a helpful container entrypoint that reaps zombie
    #   processes and such of the actual executable we want to start, see
    #   https://github.com/krallin/tini#why-tini for details.
    tini && \
    docker-clean && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen

# Configure environment
ENV CONDA_DIR=/opt/conda \
    SHELL=/bin/bash \
    NB_USER=scoped \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8
ENV PATH="${CONDA_DIR}/bin:${PATH}" \
    HOME="/home/${NB_USER}"

# Pin python version here, or set it to "default"
ARG PYTHON_VERSION=3.10

COPY extras/initial-condarc "${CONDA_DIR}/.condarc"
WORKDIR /tmp
RUN set -x && \
    arch=$(uname -m) && \
    if [ "${arch}" = "x86_64" ]; then \
    # Should be simpler, see <https://github.com/mamba-org/mamba/issues/1437>
    arch="64"; \
    fi && \
    wget -qO /tmp/micromamba.tar.bz2 \
    "https://micromamba.snakepit.net/api/micromamba/linux-${arch}/latest" && \
    tar -xvjf /tmp/micromamba.tar.bz2 --strip-components=1 bin/micromamba && \
    rm /tmp/micromamba.tar.bz2 && \
    PYTHON_SPECIFIER="python=${PYTHON_VERSION}" && \
    if [[ "${PYTHON_VERSION}" == "default" ]]; then PYTHON_SPECIFIER="python"; fi && \
    if [ "${arch}" == "aarch64" ]; then \
    # Prevent libmamba from sporadically hanging on arm64 under QEMU
    # <https://github.com/mamba-org/mamba/issues/1611>
    # We don't use `micromamba config set` since it instead modifies ~/.condarc.
    echo "extract_threads: 1" >> "${CONDA_DIR}/.condarc"; \
    fi && \
    # Install the packages
    ./micromamba install \
    --root-prefix="${CONDA_DIR}" \
    --prefix="${CONDA_DIR}" \
    --yes \
    "${PYTHON_SPECIFIER}" \
    'mamba' \
    'notebook' \
    'jupyterhub' \
    'jupyterlab' && \
    rm micromamba && \
    # Pin major.minor version of python
    mamba list python | grep '^python ' | tr -s ' ' | cut -d ' ' -f 1,2 >> "${CONDA_DIR}/conda-meta/pinned" && \
    jupyter notebook --generate-config && \
    mamba clean --all -f -y && \
    npm cache clean --force && \
    jupyter lab clean && \
    rm -rf "/home/${NB_USER}/.cache/yarn" && \
    rm -rf "/home/${NB_USER}/.npm" && \
    docker-clean

# Install all OS dependencies for fully functional notebook server
RUN apt-get update --yes && \
    apt-get install --yes --no-install-recommends \
    # Common useful utilities
    git \
    nano-tiny \
    tzdata \
    unzip \
    vim-tiny \
    # Inkscape is installed to be able to convert SVG files
    inkscape \
    # git-over-ssh
    openssh-client \
    # less is needed to run help in R
    # see: https://github.com/jupyter/docker-stacks/issues/1588
    less \
    # nbconvert dependencies
    # https://nbconvert.readthedocs.io/en/latest/install.html#installing-tex
    texlive-xetex \
    texlive-fonts-recommended \
    texlive-plain-generic && \
    apt remove -y python3.10 && apt autoremove -y && \
    docker-clean

########################################
# Configure container startup
########################################

ENTRYPOINT ["tini", "-s", "-g", "--", "/entry.sh", "/usr/bin/startup.sh"]

COPY extras/startup.sh /usr/bin/
RUN chmod +x /usr/bin/startup.sh

WORKDIR "${HOME}"
