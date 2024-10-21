# Copyright (C) The IETF Trust (2019)
#

YEAR=`date +%Y`
MONTH=`date +%B`
DAY=`date +%d`
VERS=02

BASEDOC=draft-haynes-nfsv4-erasure-encoding

all: $(BASEDOC)-$(VERS).xml

$(BASEDOC)-$(VERS).xml: $(BASEDOC).xml
	sed -e s/VERSIONVAR/${VERS}/g -e s/DAYVAR/${DAY}/g -e s/MONTHVAR/${MONTH}/g -e s/YEARVAR/${YEAR}/g < $(BASEDOC).xml > $@

text: $(BASEDOC)-$(VERS).xml
	xml2rfc --text $(BASEDOC)-$(VERS).xml
