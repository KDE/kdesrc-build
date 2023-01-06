SET(ASCIIDOCTOR_SOURCES
    index.adoc
    ksb/Module.adoc
    )

# Disable use of external resources by default in the stylesheet
SET(ASCIIDOCTOR_OPTS -a 'webfonts!')

# The most proper way to do this is to have each *.html file individually
# depend upon its *.adoc file, but asciidoctor is quick enough to just
# re-build everything each time any of those files change.
list(TRANSFORM ASCIIDOCTOR_SOURCES
    PREPEND "${CMAKE_CURRENT_SOURCE_DIR}/"
    OUTPUT_VARIABLE ABS_SRC_PATH
    )

# Note: writes to source directory by default, not build directory!
# Use "git clean -dfx" to easily completely clean a source directory.
add_custom_target(doc-sources
    COMMAND ${ASCIIDOCTOR_PATH} ${ASCIIDOCTOR_OPTS} ${ABS_SRC_PATH}
    DEPENDS "${ASCIIDOCTOR_SOURCES}"
    )
