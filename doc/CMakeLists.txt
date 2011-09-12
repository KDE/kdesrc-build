########### install files ###############
kde4_create_handbook(index.docbook INSTALL_DESTINATION ${HTML_INSTALL_DIR}/en SUBDIR kdesrc-build)
kde4_create_manpage(man-kdesrc-build.1.docbook 1 INSTALL_DESTINATION ${MAN_INSTALL_DIR})

install(PROGRAMS kdesrc-build.desktop DESTINATION ${XDG_APPS_INSTALL_DIR})
