project(kdesrc-build) # Yes, just redo it, it's makes everything install right

########### install files ###############
kde4_create_handbook(index.docbook INSTALL_DESTINATION ${HTML_INSTALL_DIR}/en)
