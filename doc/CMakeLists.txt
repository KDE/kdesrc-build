########### install files ###############
kdoctools_create_handbook(index.docbook INSTALL_DESTINATION ${HTML_INSTALL_DIR}/en SUBDIR kdesrc-build)
kdoctools_create_manpage(man-kdesrc-build.1.docbook 1 INSTALL_DESTINATION ${MAN_INSTALL_DIR})
kdoctools_create_manpage(man-kdesrc-build-setup.1.docbook 1 INSTALL_DESTINATION ${MAN_INSTALL_DIR})

install(PROGRAMS kdesrc-build.desktop DESTINATION ${XDG_APPS_INSTALL_DIR})

# Look for asciidoctor for source reference
find_program(ASCIIDOCTOR_PATH asciidoctor)

if (ASCIIDOCTOR_PATH)
    add_subdirectory(source-reference)
else()
    message(STATUS "Could not find asciidoctor, will not build developer source reference")
endif()
