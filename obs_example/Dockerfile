FROM opensuse:latest

# Make obs_pkg_mgr available
ARG OBS_REPOSITORY_URL
ADD obs_pkg_mgr /usr/bin/obs_pkg_mgr
RUN chmod +x /usr/bin/obs_pkg_mgr

RUN obs_pkg_mgr add_repo http://download.opensuse.org/repositories/Virtualization:/containers/openSUSE_Leap_42.2/ "Virtualization:Containers (openSUSE_Leap_42.2)" && ls ; obs_pkg_mgr add_repo http://example.com/my_project:/mysubproject/my_package/ "My example project" && ls

RUN obs_pkg_mgr install util-linux calcurse # amarok
RUN obs_pkg_mgr install awk gcc \
  which

RUN ls # irrelevant command before additional dependencies

RUN obs_pkg_mgr install glibc \
  file-magic && ls ; ls -la ; obs_pkg_mgr install nethogs

RUN obs_pkg_mgr install ssh-contact dumb-init; ls && ls -la
