#!/bin/bash
#+------------------------------------------------------------------------------------------------------------------------------+
#| DBpedia Spotlight - Create database-backed model                                                                             |
#| @author Joachim Daiber                                                                                                       |
#+------------------------------------------------------------------------------------------------------------------------------+

# $1 ignore.list directory or None
# $2 Working directory
# $3 Locale (en_US)
# $4 Stopwords file
# $5 Analyzer+Stemmer language prefix e.g. Dutch
# $6 Model target folder
# $7 databus folder
# $8 artifact version

export MAVEN_OPTS="-Xmx26G"

usage ()
{
  echo "index_db.sh"
  echo "usage: ./index_db.sh nl/ignore.list wdir nl_NL nl/stopwords.nl.list Dutch models/nl"
  echo "Create and upload a databus artifact of a DBpedia spotlihgt model and their stats for a specified language."
  echo " "
}

opennlp="None"
eval="false"
blacklist="false"

if [[ "$1" != "None" ]]; then
  blacklist=$1
fi


shift $((OPTIND - 1))

if [ $# != 8 ]
then
    usage
    exit
fi

BASE_DIR=$(pwd)
cd $BASE_DIR && cd ..
BASE_DIR=$(pwd)

function get_path {
  if [[ "$1"  = /* ]]
  then
    echo "$1"
  else
   echo "$BASE_DIR/$1"
  fi
}

BASE_WDIR=$(get_path $2)
BASE_ARTIFACTDIR=$(get_path $7)
TARGET_DIR=$(get_path $6)
STOPWORDS=$(get_path $4)
WDIR="$BASE_WDIR/$3"
ARTIFACT_VERSION=$8
if [[ "$blacklist" != "false" ]]; then
  blacklist=$(get_path $blacklist)
fi

LANGUAGE=`echo $3 | sed "s/_.*//g"`

echo "Language: $LANGUAGE"
echo "Working directory: $WDIR"

mkdir -p $WDIR

########################################################################################################
# Preparing the data.
########################################################################################################

echo "Loading Wikipedia dump..."
if [ -z "$WIKI_MIRROR" ]; then
  WIKI_MIRROR="https://dumps.wikimedia.org/"
fi

WP_DOWNLOAD_FILE=$WDIR/dump.xml
echo Checking for wikipedia dump at $WP_DOWNLOAD_FILE
if [ -f "$WP_DOWNLOAD_FILE" ]; then
  echo File exists.
else
  echo Downloading wikipedia dump.
  if [ "$eval" == "false" ]; then
    curl -# "$WIKI_MIRROR/${LANGUAGE}wiki/latest/${LANGUAGE}wiki-latest-pages-articles.xml.bz2" | bzcat > $WDIR/dump.xml
  else
    curl -# "$WIKI_MIRROR/${LANGUAGE}wiki/latest/${LANGUAGE}wiki-latest-pages-articles.xml.bz2" | bzcat | python $BASE_DIR/scripts/split_train_test.py 1200 $WDIR/heldout.txt > $WDIR/dump.xml
  fi
fi

cd $WDIR
cp $STOPWORDS stopwords.$LANGUAGE.list

touch "$LANGUAGE.tokenizer_model"


########################################################################################################
# DBpedia extraction:
########################################################################################################

######     #    #######    #    ######  #     #  #####
#     #   # #      #      # #   #     # #     # #     #
#     #  #   #     #     #   #  #     # #     # #
#     # #     #    #    #     # ######  #     #  #####
#     # #######    #    ####### #     # #     #       #
#     # #     #    #    #     # #     # #     # #     #
######  #     #    #    #     # ######   #####   #####

echo " Downloading the latest version of the following artifacts: 
* https://databus.dbpedia.org/dbpedia/generic/disambiguations
* https://databus.dbpedia.org/dbpedia/generic/redirects
* https://databus.dbpedia.org/dbpedia/mappings/instance-types

Note of deviation from original index_db.sh: 
takes the direct AND transitive version of redirects and instance-types and the redirected version of disambiguation 
"
cd $BASE_WDIR

QUERY="PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX dc: <http://purl.org/dc/elements/1.1/>
PREFIX dataid: <http://dataid.dbpedia.org/ns/core#>
PREFIX dataid-cv: <http://dataid.dbpedia.org/ns/cv#>
PREFIX dct: <http://purl.org/dc/terms/>
PREFIX dcat: <http://www.w3.org/ns/dcat#>

SELECT  ?file WHERE {
    { 
    # Subselect latestVersion by artifact
    SELECT  ?artifact (max(?version) as ?latestVersion)  WHERE {
            ?dataset dataid:artifact ?artifact .
            ?dataset dct:hasVersion ?version
            FILTER (?artifact in (
            # GENERIC 
                <https://databus.dbpedia.org/dbpedia/generic/disambiguations> ,
                <https://databus.dbpedia.org/dbpedia/generic/redirects> ,
                # MAPPINGS
                <https://databus.dbpedia.org/dbpedia/mappings/instance-types>
              # latest ontology, currently @denis account
              # TODO not sure if needed for Spotlight
                # <https://databus.dbpedia.org/denis/ontology/dbo-snapshots>
             )) .
             }GROUP BY ?artifact 
  } 
      
    ?dataset dct:hasVersion ?latestVersion .
    {
          ?dataset dataid:artifact ?artifact .
          ?dataset dcat:distribution ?distribution .
          ?distribution dcat:downloadURL ?file .
          ?distribution dataid:contentVariant '$LANGUAGE'^^xsd:string .
          # remove debug info 
          MINUS {
               ?distribution dataid:contentVariant ?variants . 
               FILTER (?variants in ('disjointDomain'^^xsd:string, 'disjointRange'^^xsd:string))
          }     
    }   
} ORDER by ?artifact
"

# execute query and trim " and first line from result set
RESULT=`curl --data-urlencode query="$QUERY" --data-urlencode format="text/tab-separated-values" https://databus.dbpedia.org/repo/sparql | sed 's/"//g' | grep -v "^file$" `

# Download
TMPDOWN="dump-tmp-download"
mkdir $TMPDOWN 
cd $TMPDOWN
for i in $RESULT
  do  
      wget $i 
      ls
      echo $TMPDOWN
      pwd
  done

cd ..

echo "decompressing"
bzcat -v $TMPDOWN/instance-types*.ttl.bz2 > $WDIR/instance_types.nt
bzcat -v $TMPDOWN/disambiguations*.ttl.bz2 > $WDIR/disambiguations.nt
bzcat -v $TMPDOWN/redirects*.ttl.bz2 > $WDIR/redirects.nt

# clean
rm -r $TMPDOWN

########################################################################################################
# Setting up Spotlight:
########################################################################################################

cd $BASE_WDIR

if [ -d dbpedia-spotlight ]; then
    echo "Updating DBpedia Spotlight..."
    cd dbpedia-spotlight
    git reset --hard HEAD
    git pull
    mvn -T 1C -q -Dhttps.protocols=TLSv1.2 clean install
else
    echo "Setting up DBpedia Spotlight..."
    git clone --depth 1 https://github.com/dbpedia-spotlight/dbpedia-spotlight-model
    mv dbpedia-spotlight-model dbpedia-spotlight
    cd dbpedia-spotlight
    #mvn -T 1C -q -Dhttps.protocols=TLSv1.2 install
fi


########################################################################################################
# Extracting wiki stats:
########################################################################################################

cd $BASE_WDIR
rm -Rf wikistatsextractor
git clone --depth 1 https://github.com/dbpedia-spotlight/wikistatsextractor

# Stop processing if one step fails
set -e

#Copy results to local:
cd $BASE_WDIR/wikistatsextractor

echo "MVN ARGUMENTS --output_folder $WDIR $LANGUAGE $3 $5Stemmer $WDIR/dump.xml $WDIR/stopwords.$LANGUAGE.list"

mvn install exec:java -Dexec.args="--output_folder $WDIR $LANGUAGE $3 $5Stemmer $WDIR/dump.xml $WDIR/stopwords.$LANGUAGE.list"

if [ "$blacklist" != "false" ]; then
  echo "Removing blacklist URLs..."
  mv $WDIR/uriCounts $WDIR/uriCounts_all
  grep -v -f $blacklist $WDIR/uriCounts_all > $WDIR/uriCounts
fi

echo "Finished wikistats extraction. Cleaning up..."
#rm -f $WDIR/dump.xml

########################################################################################################
# Building Spotlight model:
########################################################################################################

#Create the model:
cd $BASE_WDIR/dbpedia-spotlight

#mvn -Dhttps.protocols=TLSv1.2 install

mvn -pl index exec:java -Dexec.mainClass=org.dbpedia.spotlight.db.CreateSpotlightModel -Dexec.args="$3 $WDIR $TARGET_DIR $opennlp $STOPWORDS $5Stemmer"

if [ "$eval" == "true" ]; then
  mvn -pl eval exec:java -Dexec.mainClass=org.dbpedia.spotlight.evaluation.EvaluateSpotlightModel -Dexec.args="$TARGET_DIR $WDIR/heldout.txt" > $TARGET_DIR/evaluation.txt
fi

curl https://raw.githubusercontent.com/dbpedia-spotlight/model-quickstarter/master/model_readme.txt > $TARGET_DIR/README.txt
curl "$WIKI_MIRROR/${LANGUAGE}wiki/latest/${LANGUAGE}wiki-latest-pages-articles.xml.bz2-rss.xml" | grep link | sed -e 's/^.*<link>//' -e 's/<[/]link>.*$//' | uniq >> $TARGET_DIR/README.txt

###########################################
# Generating artifacts
#############################################

set -e

MODEL_DIR="spotlight-model"
WIKISTAT_DIR="spotlight-wikistats"
#DERIVE_DATE=$(date +%F | sed 's/-/\./g')
DERIVE_DATE="2020.03.11"

#compressing model files
cd $TARGET_DIR/..
echo pwd
echo tar -cvzf $BASE_ARTIFACTDIR/$MODEL_DIR/$ARTIFACT_VERSION/spotlight-model_lang\=$LANGUAGE.tar.gz "$LANGUAGE" && echo "$LANGAUGE"
tar -cvzf $BASE_ARTIFACTDIR/$MODEL_DIR/$ARTIFACT_VERSION/spotlight-model_lang\=$LANGUAGE.tar.gz "$LANGUAGE" && echo rm -r $LANGAUGE

#compressing wikistats files
cd $WDIR

bzip2 -zk *Counts && echo "bzip finished"
rename "s/^/spotlight-wikistats_type=/" *Counts.bz2 && rename "s/Counts.bz2/Counts_lang=$LANGUAGE.tsv.bz2/" * && mv *tsv.bz2 $BASE_ARTIFACTDIR/$WIKISTAT_DIR/$ARTIFACT_VERSION/

#find . -name "*Counts.tsv" | tar -cvzf $ARTIFACT_DIR/$WIKISTAT_DIR/$DERIVE_DATE/spotlight-wikistat_lang\=$LANGUAGE.tar.gz --files-from - && echo "wikistats are done"

############################################
# Moving files
############################################

#echo "Collecting data..."
#cd $BASE_DIR
#mkdir -p data/$LANGUAGE && mv $WDIR/*Counts data/$LANGUAGE
#gzip $WDIR/*.nt &
rm -r $WDIR
set +e