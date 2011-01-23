########### install files ###############
kde4_create_handbook(index.docbook INSTALL_DESTINATION ${HTML_INSTALL_DIR}/en SUBDIR kdesrc-build)

install(PROGRAMS kdesrc-build.desktop DESTINATION ${XDG_APPS_INSTALL_DIR})
