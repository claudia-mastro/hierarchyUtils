% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/interval_assertions.R
\name{assert_no_overlapping_intervals}
\alias{assert_no_overlapping_intervals}
\alias{identify_overlapping_intervals}
\title{Does the interval variable have any overlapping intervals?}
\usage{
assert_no_overlapping_intervals(ints_dt)

identify_overlapping_intervals(ints_dt)
}
\arguments{
\item{ints_dt}{[\code{data.table()}]\cr
Unique intervals. The first column represents the start of each interval
and the second column represents the end of each interval.}
}
\value{
\code{identify_overlapping_intervals} returns a [\code{data.table()}] with
columns for the 'start' and 'end' of the overlapping intervals. If no
intervals are overlapping then a zero-row [\code{data.table()}] is returned.
\code{assert_no_overlapping_intervals} returns nothing but throws an error if
\code{identify_overlapping_intervals} returns a non-empty data.table.
}
\description{
Checks to see if the input interval variable has any
overlapping intervals.
}
\examples{
ints_dt <- data.table::data.table(
  start = c(seq(0, 95, 5), 0),
  end = c(seq(5, 95, 5), Inf, Inf)
)
overlapping_dt <- identify_overlapping_intervals(ints_dt)


}
