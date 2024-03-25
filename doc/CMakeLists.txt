########### install files ###############
kdoctools_create_handbook(index.docbook INSTALL_DESTINATION ${KDE_INSTALL_DOCBUNDLEDIR}/en SUBDIR kdesrc-build)
kdoctools_create_manpage(man-kdesrc-build.1.docbook 1 INSTALL_DESTINATION ${KDE_INSTALL_MANDIR})

install(PROGRAMS kdesrc-build.desktop DESTINATION ${KDE_INSTALL_APPDIR})
