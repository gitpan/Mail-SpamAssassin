#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <iostream.h>
#include <fstream.h>

/**
 *  Requires GAlib from http://lancet.mit.edu/ga/ to run.
 */

#include <ga/ga.h>
#include <ga/GARealGenome.h>
#include <ga/GARealGenome.C>

extern "C" {
#include "tmp/scores.h"
#include "tmp/tests.h"
}

// ---------------------------------------------------------------------------

int threshold = 5;	// threshold of spam vs. non-spam

int nn, ny, yn, yy;	// simple number of y/n diagnoses

// These floats are the same as above, but massively-y or massively-n scores
// count extra.  This encourages clear decisions about spam or not.
//
float nnscore, nyscore, ynscore, yyscore;

float nybias	= 5.0;
int sleepTime	= 0;		// time to sleep during runs

float float_num_spam;
float float_num_nonspam;

// ---------------------------------------------------------------------------

void printhits (FILE *fout) {
  if (num_tests == 0) { num_tests = 1; }

  fprintf (fout, "# SUMMARY:            %6d / %6d\n#\n",
      	ny, yn);

  fprintf (fout,
"# Correctly non-spam: %6d  %3.2f%%  (%3.2f%% overall, %6.0f adjusted)\n",
        nn, (nn / (float) num_nonspam) * 100.0,
        (nn / (float) num_tests) * 100.0, nnscore);

  fprintf (fout,
"# Correctly spam:     %6d  %3.2f%%  (%3.2f%% overall, %6.0f adjusted)\n",
        yy, (yy / (float) num_spam) * 100.0,
	(yy / (float) num_tests) * 100.0, yyscore);

  fprintf (fout,
"# False positives:    %6d  %3.2f%%  (%3.2f%% overall, %6.0f adjusted)\n",
        ny, (ny / (float) num_nonspam) * 100.0,
	(ny / (float) num_tests) * 100.0, nyscore);

  fprintf (fout,
"# False negatives:    %6d  %3.2f%%  (%3.2f%% overall, %6.0f adjusted)\n",
        yn, (yn / (float) num_spam) * 100.0,
	(yn / (float) num_tests) * 100.0, ynscore);

  fprintf (fout, "# TOTAL:              %6d  %3.2f%%\n#\n",
        num_tests, 100.0);
}

// ---------------------------------------------------------------------------

void writescores (FILE *fout) {
  int i;
  float score;

  for (i = 0; i < num_scores-1; i++) {
    score = scores[i];
    fprintf (fout, "score %-30s %2.1f\n", score_names[i], score);
  }
}

// ---------------------------------------------------------------------------

void counthitsfromscores (void) {
  int file;
  float hits;
  int i;

  nn = ny = yn = yy = 0;
  nnscore = nyscore = ynscore = yyscore = 0.0;

  for (file = 0; file < num_tests; file++) {
    float score;

    hits = 0.0;
    for (i = num_tests_hit[file]-1; i >= 0; i--) {
      score = scores[tests_hit[file][i]];
      hits += score;
    }

    // divide by 50 so we get e.g.
    // 1.02 for a positive spam which is 1 pt over the threshold
    if (is_spam[file]) {
      if (hits > threshold) {
	yy++;
	// maximise diff between hits and threshold
	yyscore += ((hits - threshold) / 50.0) + 1.0;
      } else {
	yn++;
	// penalise diff between hits and threshold. bigger is worse
	ynscore += ((threshold - hits) / 50.0) + 1.0;
      }
    } else {
      if (hits > threshold) {
	ny++;
	// penalise diff between hits and threshold. bigger is worse
	nyscore += ((hits - threshold) / 50.0) + 1.0;
      } else {
	nn++;
	// maximise diff between hits and threshold
	nnscore += ((threshold - hits) / 50.0) + 1.0;
      }
    }
  }
}

// ---------------------------------------------------------------------------

void counthits (GARealGenome &genome) {
  int i, len;

  len = genome.length();
  if (len != num_scores) {
    cerr << "len != numscores: "<<len<<"  "<<num_scores<<endl;
    exit(1);
  }

  // copy the new scores to the "scores" array
  for (i = 0; i < len; i++) {
    if (is_mutatable[i]) {
      scores[i] = genome[i];
      if (scores[i] == 0.0) { scores[i] = 0.1; }

    } else {
      scores[i] = bestscores[i];	// use the standard one
    }
  }

  counthitsfromscores();
}

// ---------------------------------------------------------------------------

// add up all the incorrect diagnoses, and use that as the fitness
// score.  Since we're trying to minimise the objective, this should
// work OK -- we want it to be as low as possible.
//
float
objective(GAGenome & c)
{
  GARealGenome &genome = (GARealGenome &) c;
  counthits(genome);

  if (sleepTime) { usleep(sleepTime); }

  // old old version; just use the # of messages
  // return ((float) yn + (ny * nybias));

  // old version: use the proportion of messages to messages in the
  // correct category.
  //return (float) ((yn / (float) num_spam)
    		//+ ((ny * nybias) / (float) num_nonspam));

  // new version: similar to above, but penalise scores that
  // are way off.
  return (float) ((ynscore / float_num_spam)
      		+ ((nyscore * nybias) / float_num_nonspam));
}

// ---------------------------------------------------------------------------

void
write_to_file (GARealGenome &genome, const char *fname) {
  FILE *fout;
  char namebuf[255];

  counthits(genome);
  snprintf (namebuf, 255, "%s", fname);
  fout = fopen (namebuf, "w");
  printhits (fout);
  writescores (fout);
  fclose (fout);
}

// ---------------------------------------------------------------------------

void
fill_allele_set (GARealAlleleSetArray *setary)
{
  float hi, lo;
  int i;

  for (i = 0; i < num_scores; i++) {
    if (is_mutatable[i]) {
      hi = range_hi[i];
      lo = range_lo[i];
    } else {
      hi = bestscores[i];
      lo = bestscores[i];
    }
    setary->add (lo, hi);
  }
}

// ---------------------------------------------------------------------------

void usage () {
  cerr << "usage: evolve -s size [args]\n"
    << "\n"
    << "  -z sleeptime = time to sleep in msecs (0 default, 10 = 33% cpu usage)\n"
    << "  -s size = population size (300 recommended)\n"
    << "  -b nybias = bias towards false negatives (5.0 default)\n"
    << "\n"
    << "  -g ngens = generations to run (1500 default)\n"
    << "  -c conv = run until convergence (1.00 default)\n"
    << "  -m npops = migration with multi populations (5 default)\n"
    << "\n"
    << "  -g and -c are mutually exclusive.\n"
    << "  Steady-state mode is default, unless -m is used -- but currently\n"
    << "  -m is unimplemented; you need to edit code to do it. sorry.\n"
    <<endl;
  exit (30);
}

int
main (int argc, char **argv) {
  int arg;
  int demeMode	= 0;
  int convergeMode = 0;
  int justCount = 0;
  int npops	= 5;		// num pops (for deme mode)
  int popsize	= 0;		// population size
  int generations = 1500;	// generations to run
  float pconv	= 1.00;		// threshhold for when we have converged
  int nconv	= 300;		// how many gens back to check for convergence

  while ((arg = getopt (argc, argv, "b:c:s:m:g:Cz:")) != -1) {
    switch (arg) {
      case 'b':
	nybias = atof(optarg);
	break;

      case 's':
	popsize = atoi(optarg);
	break;

      case 'm':
	demeMode = 1;
	fprintf (stderr, "Deme mode not supported through cmdline args yet\n");
	usage();
	npops = atoi(optarg);
	break;

      case 'c':
	convergeMode = 1;
	pconv = atof(optarg);
	break;

      case 'C':
	justCount = 1;
	break;

      case 'g':
	demeMode = 0;
	generations = atoi(optarg);
	break;

      case 'z':
	sleepTime = atoi(optarg);
	break;

      case '?':
	usage();
	break;
    }
  }

  loadscores ();
  loadtests ();

  float_num_spam = (float) num_spam;
  float_num_nonspam = (float) num_nonspam;

  if (justCount) {
    cout << "Counts for current genome:" << endl;

    // copy the base scores to the "scores" array
    int i;
    for (i = 0; i < num_scores; i++) {
      scores[i] = bestscores[i];
    }

    counthitsfromscores();
    printhits (stdout);
    exit (0);
  }

  if (popsize == 0) { usage(); }

  GARandomSeed();	// use time ^ $$

  // allow scores from -0.5 to 4.0 inclusive, in jumps of 0.1
  GARealAlleleSetArray allelesetarray;
  fill_allele_set (&allelesetarray);
  GARealGenome genome(allelesetarray, objective);

  // use our score-perturbing initialiser, the default
  // gaussian mutator, and crossover.

  // don't let the genome change its length
  genome.resizeBehaviour (num_scores, num_scores);

  // steady-state seems to give best results
  GASteadyStateGA ga(genome);

  // incremental, faster but not as good
  //GAIncrementalGA ga(genome);

  //GADemeGA ga(genome);
  //ga.nPopulations(npops);

  ga.populationSize(popsize);

  if (convergeMode) {
    ga.pConvergence(pconv);
    ga.nConvergence(nconv);
    ga.terminator(GAGeneticAlgorithm::TerminateUponConvergence);
  } else {
    ga.set(gaNnGenerations, generations);        // number of generations
  }

  ga.minimize();		// we want to minimize the objective
  ga.set(gaNpCrossover, 0.6);           // probability of crossover
  ga.set(gaNpMutation, 0.05);           // probability of mutation
  ga.set(gaNscoreFrequency, 1);         // how often to record scores
  ga.set(gaNflushFrequency, 20);        // how often to dump scores to file
  ga.set(gaNselectScores,               // which scores should we track?
         GAStatistics::AllScores);
  ga.set(gaNscoreFilename, "evolve.scores");
  ga.parameters(argc, argv);

  cout << "Run this to watch progress scores:" << endl
    	<< "\ttail -f evolve.scores" << endl;
  cout << "evolving...\n";

  int gens = 0;
  while(!ga.done()) {
    ga.step();
    gens++;

    if (gens % 5 == 0) {
      cout << "."; cout.flush();

      if (gens % 300 == 0) {
	cout << "\nProgress: gen=" << gens << " convergence="
	  	<< ga.statistics().convergence()
	  	<< ":\n";

	genome = ga.statistics().bestIndividual();
	counthits(genome); printhits (stdout);
	write_to_file (genome, "tmp/results.in_progress");
      }
    }
  }
  cout << endl;

  genome = ga.statistics().bestIndividual();

  cout << "Best genome found:" << endl;
  counthits(genome);
  printhits (stdout);
  //cout << "Stats:\n" << ga.statistics() << endl;

  write_to_file (genome, "results.evolved");
  cout << "Scores for this genome written to \"results.evolved\"." << endl;
  return 0;
}

