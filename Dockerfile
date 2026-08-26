FROM rockylinux/rockylinux:10

ENV R_VERSION=4.6.1

RUN dnf install -y epel-release && crb enable 

RUN dnf install https://cdn.posit.co/r/rhel-10/pkgs/R-${R_VERSION}-1-1.$(arch).rpm -y

COPY install_packages.R packages.csv /tmp/

RUN mkdir -p /opt/site-library

RUN /opt/R/$R_VERSION/bin/Rscript /tmp/install_packages.R --csv /tmp/packages.csv --packages --sysdeps --site-library /opt/site-library