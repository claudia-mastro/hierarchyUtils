#' @title Create a data.tree object to be used for aggregating or scaling
#'   hierarchical categorical or interval data
#'
#' @description Creates a hierarchical data.tree object that defines how
#' different levels of categorical or interval data are related to each other.
#'
#' @inheritParams agg
#' @param exists \[`character()`\]\cr
#'   names of variables in the mapping that data exists for.
#'
#' @details
#' [Hierarchical tree data structures](https://en.wikipedia.org/wiki/Tree_(data_structure))
#' are used to represent different levels of the categorical or interval data.
#' The r package \pkg{data.tree} is used to implement these data structures.
#'
#' When [vis_tree()] is used to visualize a tree returned by [create_agg_tree()]
#' then nodes with data directly provided are colored green, nodes where
#' aggregation is possible are colored blue, and missing nodes without data
#' directly provided and where aggregation is impossible because of the missing
#' nodes are colored red.
#'
#' When [vis_tree()] is used to visualize a tree returned by
#' [create_scale_tree()] then nodes with data directly provided and that can be
#' scaled are colored green, nodes with data directly provided but that can not
#' be scaled are colored blue and nodes without data directly provided
#'
#' @return [create_agg_tree()] and [create_scale_tree()] return a
#'   \[`data.tree()`\] with fields for whether each node has data available
#'   ('exists') and whether aggregation to or scaling of each node is possible
#'   ('agg_possible' or 'scale_possible'). For [create_scale_tree()], also
#'   includes a field for whether children of each node can be scaled
#'   ('scale_children_possible').
#'
#'   [vis_tree()] uses [networkD3::diagonalNetwork()] to create 'D3' network
#'   graphs.
#'
#' @examples
#' # aggregation example where all present day locations exist except for Tehran
#' locations_present <- iran_mapping[!grepl("[0-9]+", child) &
#'                                    child != "Tehran", child]
#' agg_tree <- create_agg_tree(iran_mapping, exists = locations_present,
#'                             col_type = "categorical")
#' vis_tree(agg_tree)
#'
#' # scaling example where all present day locations exist without collapsing
#' locations_present <- c(iran_mapping[!grepl("[0-9]+", child), child], "Iran")
#' scale_tree <- create_scale_tree(iran_mapping,
#'                                 exists = locations_present,
#'                                 col_type = "categorical")
#' vis_tree(scale_tree)
#'
#' # scaling example where all present day locations exist and collapsing tree
#' scale_tree <- create_scale_tree(iran_mapping,
#'                                 exists = locations_present,
#'                                 col_type = "categorical",
#'                                 collapse = TRUE)
#' vis_tree(scale_tree)
#'
#' @export
#' @rdname create_tree
create_agg_tree <- function(mapping, exists, col_type) {

  tree <- create_base_tree(mapping, exists, col_type)

  # check which groups we can aggregate to given the values already available
  check_agg_possible <- function(x) {
    if (data.tree::isLeaf(x)) {
      return(data.tree::GetAttribute(x, "exists"))
    } else {
      # if an interval tree check that children nodes cover entire interval span
      if (col_type == "interval") {
        start <- sapply(x$children, function(child) {
          return(data.tree::GetAttribute(child, "left"))
        })
        end <- sapply(x$children, function(child) {
          return(data.tree::GetAttribute(child, "right"))
        })
        missing_intervals <- identify_missing_intervals(
          data.table(start, end), data.table(x$left, x$right)
        )
        if (nrow(missing_intervals) != 0) {
          return(FALSE)
        }
      }
      # if not a leaf check that all children have data or can themselves be
      # aggregated to
      values <- sapply(x$children, function(child) {
        return(data.tree::GetAttribute(child, "exists") |
                 data.tree::GetAttribute(child, "agg_possible"))
      })
      return(unname(all(values)))
    }
  }
  tree$Do(function(x) x$agg_possible <- check_agg_possible(x),
          traversal = "post-order")

  return(tree)
}

#' @export
#' @rdname create_tree
create_scale_tree <- function(mapping,
                              exists,
                              col_type,
                              collapse_missing = FALSE) {

  tree <- create_base_tree(mapping, exists, col_type)

  if (collapse_missing & col_type == "categorical") collapse_tree(tree)


  # check which groups we can scale given the values available
  check_scale_possible <- function(x) {
    if (data.tree::isRoot(x)) {
      return (FALSE)
    } else {

      # check that the node and its siblings cover the entire interval and don't
      # overlap at all
      if (col_type == "interval") {
        start <- sapply(c(x, x$siblings), function(sib) {
          return(data.tree::GetAttribute(sib, "left"))
        })
        end <- sapply(c(x, x$siblings), function(sib) {
          return(data.tree::GetAttribute(sib, "right"))
        })
        missing_intervals <- identify_missing_intervals(
          data.table(start, end), data.table(x$parent$left, x$parent$right)
        )
        overlapping_intervals <- identify_overlapping_intervals(
          data.table(start, end)
        )
        if (nrow(missing_intervals) != 0 | nrow(overlapping_intervals) != 0) {
          return(FALSE)
        }
      }

      # check that the node, parent, and all its siblings values available
      siblings <- sapply(x$siblings, function(sibling) {
        return(data.tree::GetAttribute(sibling, "exists"))
      })
      return(data.tree::GetAttribute(x, "exists") &
               data.tree::GetAttribute(x$parent, "exists") & all(siblings))
    }
  }
  tree$Do(function(x) x$scale_possible <- check_scale_possible(x),
          traversal = "pre-order")

  # check which nodes can have their children nodes scaled and themselves exist
  check_children_scale_possible <- function(x) {
    if (data.tree::isLeaf(x)) {
      return (FALSE)
    } else { # check that all its children can be scaled values available
      children <- sapply(x$children, function(child) {
        return(data.tree::GetAttribute(child, "scale_possible"))
      })
      return(data.tree::GetAttribute(x, "exists") & all(children))
    }
  }
  tree$Do(function(x) x$scale_children_possible <- check_children_scale_possible(x),
          traversal = "pre-order")

  return(tree)
}

#' @title Create a data.tree object using a mapping of levels of a categorical
#'   or interval variable
#'
#' @inheritParams create_agg_tree
#'
#' @return \[`data.tree()`\] with field for whether each node has data
#'   available ('exists').
create_base_tree <- function(mapping, exists, col_type) {

  # create overall tree with entire mapping
  tree <- data.tree::FromDataFrameNetwork(mapping)

  # simplify node names for aggregate intervals where nodes in tree are not
  # unique and are formatted like "[0, Inf)/[0, 5)/[0, 1)"
  if (any(grepl("/", (tree$Get("name"))))) {
    filterFun <- function(x) x$level == lvl
    for (lvl in 2:tree$height) {
      # don't need the full path to each node as the name, just the last element
      tree$Set(name = tstrsplit(tree$Get("name",
                                         filterFun = filterFun),
                                "/")[[lvl]],
               filterFun = filterFun)
    }
  }

  # create left and right endpoint fields for interval trees
  if (col_type == "interval") {
    parsed_name <- name_to_start_end(tree$Get("name"))
    tree$Set(left = parsed_name$start)
    tree$Set(right = parsed_name$end)
  }

  # mark groups we have values for already
  tree$Set(exists = tree$Get('name') %in% exists)

  return(tree)
}

#' @title Collapse the data.tree so that intermediate nodes without data are
#'   removed
#'
#' @param tree \[`data.tree()`\]\cr
#'   As returned by [create_base_tree()] with information about where data
#'   exists for different levels of the categorical variables.
#'
#' @return \[`data.tree()`\] with field for whether each node has data
#'   available ('exists').
collapse_tree <- function(tree) {

  collapse <- function(x) {
    # collapse node where value doesn't exist in dataset
    if (!x$exists) {
      for (child in rev(x$children)) {
        # move children up a level to sibling of current node
        x$AddSiblingNode(child)
      }
      # actually remove current node
      x$parent$RemoveChild(x$name)
    }
  }

  tree$Do(function(x) collapse(x), traversal = "post-order",
          filterFun = function(x) data.tree::isNotLeaf(x) &
            data.tree::isNotRoot(x))
  return(tree)
}

#' @param tree \[`data.tree()`\] as returned by [create_agg_tree()] or
#'   [create_scale_tree()].
#'
#' @export
#' @rdname create_tree
vis_tree <- function(tree) {

  if (!requireNamespace("networkD3", quietly = TRUE)) {
    stop("Package \"networkD3\" needed for this function to work.
         Please install it.",
         call. = FALSE)
  }

  # determine whether this is an aggregate or scale tree
  type <- "agg"
  if ("scale_possible" %in% tree$fieldsAll) type <- "scale"

  # create node attribute for three types of nodes
  group_node <- function(x) {
    if (type == "agg") {
      if (data.tree::GetAttribute(x, "exists")) {
        return("Value Provided")
      } else if (data.tree::GetAttribute(x, "agg_possible")) {
        return("Possible")
      }

    } else if (type == "scale") {
      if (data.tree::GetAttribute(x, "exists")) {
        if (data.tree::GetAttribute(x, "scale_children_possible")) {
          return("Possible")
        } else {
          return("Value Provided")
        }
      }
    }
    return("Not Possible")
  }
  tree$Do(function(x) x$vis_group_node <- group_node(x))

  # create colour function to be passed to networkD3::diagonalNetwork
  colours <- data.table(vis_group = c("Value Provided", "Possible",
                                      "Not Possible"),
                        colour = c("green", "blue", "red"))
  colours[, vis_group := paste0('"', vis_group)]
  colours[, colour := paste0(colour, '"')]
  colours[, full := paste0(vis_group, '" : "', colour)]
  colour_function <- networkD3::JS(paste0("function(d, i) { return {",
                                          paste(colours$full, collapse = ", "),
                                          "} [d.data.vis_group_node]; }"))

  # convert to networkD3::diagonalNetwork input List
  target_list <- data.tree::ToListExplicit(tree, unname = TRUE)
  tree$Do(function(node) node$RemoveAttribute("vis_group_node"))

  networkD3::diagonalNetwork(List = target_list,
                             nodeColour = colour_function,
                             nodeStroke = colour_function)
}

#' @title Identify names of problematic nodes in categorical trees
#'
#' @description Identify names of problematic nodes that are making aggregation
#'   or scaling not possible because they are missing or the aggregates are
#'   already present.
#'
#' @inheritParams vis_tree
#'
#' @return \[`character()`\] vector with the names of the problematic nodes.
#'
#' @rdname problematic_tree_nodes
identify_missing_agg <- function(tree) {

  # identify each leaf node that is missing which makes aggregation to some
  # nodes impossible
  missing_nodes <- tree$Get(
    "name",
    filterFun = function(x) data.tree::isLeaf(x) &
      !data.tree::GetAttribute(x, "exists")
  )
  if (!is.null(missing_nodes)) {
    missing_nodes <- sort(unique(unname(missing_nodes)))
  }
  return(missing_nodes)
}

#' @rdname problematic_tree_nodes
identify_missing_scale <- function(tree) {

  if (all(c("left", "right") %in% tree$fields)) {
    col_type <- "interval"
  } else {
    col_type <- "categorical"
  }

  # identify each node that is missing which causes scaling of itself or
  # children to not be possible
  missing_nodes <- tree$Get(
    "name",
    filterFun = function(x) !data.tree::GetAttribute(x, "exists") &
      (!data.tree::GetAttribute(x, "scale_possible") |
         !data.tree::GetAttribute(x, "scale_children_possible")) &
      ifelse(col_type == "interval", data.tree::isNotRoot(x), TRUE)
  )
  if (!is.null(missing_nodes)) missing_nodes <- sort(unname(missing_nodes))
  return(missing_nodes)
}

#' @rdname problematic_tree_nodes
identify_present_agg <- function(tree) {

  # identify each non leaf node that is present already when any of its
  # children's nodes are present

  # identify each nonleaf (and its subtree) where data exists
  check_subtrees <- data.tree::Traverse(
    tree, traversal = "post-order",
    filterFun = function(x) {
      data.tree::isNotLeaf(x) & data.tree::GetAttribute(x, "exists")
    }
  )

  # check whether each subtree's parent has any children (or lower nodes) with
  # data available
  present_nodes <- lapply(check_subtrees, function(subtree) {
    subtree_exists <- subtree$Get("exists")
    lower_node_exists <- subtree_exists[names(subtree_exists) != subtree$name]
    if (any(lower_node_exists)) {
      return(subtree$name)
    }
    return(NULL)
  })
  present_nodes <- unlist(present_nodes)

  return(present_nodes)
}

#' @title Create a list of subtrees that can be used during aggregation or
#'   scaling
#'
#' @description
#' Use [data.tree::Traverse()] to create a list of subtrees that are to be used
#' during aggregation or scaling.
#'
#' For aggregation, traverses in post-order so that aggregation starts from
#' the bottom of the tree and goes up. For scaling, traverses in pre-order so
#' that scaling starts from the top of the tree and goes down.
#'
#' Only includes nodes that can be aggregated to or scaled.
#'
#' @inheritParams create_agg_tree
#'
#' @rdname create_subtrees
create_agg_subtrees <- function(mapping, exists, col_type) {

  tree <- create_agg_tree(mapping, exists, col_type)

  # identify each nonleaf where aggregation is possible and its subtree
  subtrees <- data.tree::Traverse(
    tree, traversal = "post-order",
    filterFun = function(x) {
      data.tree::isNotLeaf(x) & data.tree::GetAttribute(x, "agg_possible")
    }
  )

  # drop the last subtree since it is a mapping from the full interval to
  # each aggregate which can't be used to aggregate. It is separately
  # included as a subtree if needed
  if (col_type == "interval" & tree$agg_possible) {
    subtrees <- subtrees[-length(subtrees)]
  }

  return(subtrees)
}

#' @rdname create_subtrees
create_scale_subtrees <- function(mapping,
                                  exists,
                                  col_type,
                                  collapse_missing) {

  tree <- create_scale_tree(mapping, exists, col_type, collapse_missing)

  # identify each nonleaf (and its subtree) where scaling of children nodes is possible
  subtrees <- data.tree::Traverse(
    tree, traversal = "pre-order",
    filterFun = function(x) {
      data.tree::isNotLeaf(x) & data.tree::GetAttribute(x, "scale_children_possible")
    }
  )
  return(subtrees)
}

#' Aggregate or scale one subtree's children values to the parent level
#'
#' @inheritParams agg
#' @inheritParams identify_unique_groupings
#' @param subtree one subtree of the list returned by [create_agg_subtrees()] or
#'   [create_scale_subtrees()].
#'
#' @return \[`data.table()`\] with same input columns for requested aggregates
#' or with scaled values for the given `subtree`. [scale_subtree()] changes the
#' name of the `value_cols` to `{value_cols}_scaled`.
#'
#' @rdname agg_scale_subtree
agg_subtree <- function(dt,
                        id_cols,
                        value_cols,
                        col_stem,
                        col_type,
                        agg_function,
                        subtree,
                        missing_dt_severity,
                        collapse_interval_cols) {

  cols <- col_stem
  if (col_type == "interval") {
    cols <- paste0(col_stem, "_", c("start", "end"))
  }
  interval_id_cols <- id_cols[grepl("_start$|_end$", id_cols)]
  interval_id_cols_stems <- unique(gsub("_start$|_end$", "", interval_id_cols))
  categorical_id_cols <- id_cols[!id_cols %in% interval_id_cols]
  by_id_cols <- id_cols[!id_cols %in% cols]

  parent <- subtree$name
  children <- names(subtree$children)

  # collapse interval id columns to most detailed common intervals
  if (collapse_interval_cols) {
    for (stem in interval_id_cols_stems[interval_id_cols_stems != col_stem]) {
      dt <- collapse_common_intervals(
        dt = dt,
        id_cols = c(id_cols, if (col_type == "interval") col_stem),
        value_cols = value_cols,
        col_stem = stem,
        agg_function = agg_function,
        missing_dt_severity = missing_dt_severity,
        include_missing = FALSE
      )
    }
  }

  children_dt <- dt[get(col_stem) %in% children]
  parent_dt <- children_dt[, lapply(.SD, agg_function), .SDcols = value_cols,
                           by = by_id_cols]

  # assign aggregate columns
  if (col_type == "interval") {
    parent_dt[, paste0(col_stem, c("_start", "_end")) := name_to_start_end(parent)]
  } else {
    parent_dt[, col_stem := parent]
    setnames(parent_dt, "col_stem", col_stem)
  }
  return(parent_dt)
}

#' @rdname agg_scale_subtree
scale_subtree <- function(dt,
                          id_cols,
                          value_cols,
                          col_stem,
                          col_type,
                          agg_function,
                          subtree,
                          missing_dt_severity,
                          collapse_interval_cols) {
  parent <- subtree$name
  children <- names(subtree$children)

  cols <- col_stem
  if (col_type == "interval") {
    cols <- paste0(col_stem, "_", c("start", "end"))
  }
  interval_id_cols <- id_cols[grepl("_start$|_end$", id_cols)]
  interval_id_cols_stems <- unique(gsub("_start$|_end$", "", interval_id_cols))
  categorical_id_cols <- id_cols[!id_cols %in% interval_id_cols]
  by_id_cols <- id_cols[!id_cols %in% cols]

  agg_value_cols <- paste0(value_cols, "_agg")
  scaling_factor_value_cols <- paste0(value_cols, "_sf")
  scaled_value_cols <- paste0(value_cols, "_scaled")

  subtree_dt <- dt[get(col_stem) %in% c(parent, children)]

  # collapse interval id columns to most detailed common intervals so that
  # scaling factors can be calculated
  if (collapse_interval_cols) {
    for (stem in interval_id_cols_stems[interval_id_cols_stems != col_stem]) {
      stem_cols <- paste0(stem, "_", c("start", "end"))
      common_intervals <- identify_common_intervals(
        dt = subtree_dt,
        id_cols = c(id_cols, if (col_type == "interval") col_stem),
        col_stem = stem,
        include_missing = TRUE # these are identified below
      )
      subtree_dt <- merge_common_intervals(subtree_dt, common_intervals, stem)

      missing_dt <- subtree_dt[, identify_missing_intervals(.SD, common_intervals),
                               .SDcols = stem_cols,
                               by = setdiff(id_cols, stem_cols)]
      data.table::setnames(missing_dt, c("start", "end"), stem_cols)
      missing_dt <- merge_common_intervals(missing_dt, common_intervals, stem)
      # need to ignore the variable being aggregated so that all parent and
      # children nodes are dropped for missing intervals
      missing_dt <- missing_dt[, c(setdiff(by_id_cols, stem_cols),
                                   "common_start", "common_end"), with = F]
      missing_dt <- unique(missing_dt)
      missing_dt[, drop := TRUE]

      subtree_dt <- merge(subtree_dt, missing_dt, all = TRUE,
                          by = c(setdiff(by_id_cols, stem_cols), "common_start",
                                 "common_end"))
      subtree_dt <- subtree_dt[is.na(drop)]
      subtree_dt[, drop := NULL]
      subtree_dt[, c(stem_cols) := NULL]
      data.table::setnames(subtree_dt, c("common_start", "common_end"), stem_cols)

      # aggregate so that rows are all unique again
      subtree_dt <- subtree_dt[, lapply(.SD, agg_function),
                               .SDcols = value_cols,
                               by = c(id_cols, if (col_type == "interval") col_stem)]
    }
  }

  parent_dt <- subtree_dt[get(col_stem) %in% parent]
  children_dt <- subtree_dt[get(col_stem) %in% children]

  # aggregate children to parent level
  sum_children_dt <- agg_subtree(
    children_dt,
    id_cols,
    value_cols,
    col_stem,
    col_type,
    agg_function,
    subtree,
    missing_dt_severity,
    collapse_interval_cols
  )
  setnames(sum_children_dt, value_cols, agg_value_cols)

  # combine aggregate child node values and original parent node values
  sf_dt <- merge(parent_dt, sum_children_dt,
                 by = c(by_id_cols, cols), all = T)

  # calculate scaling factor
  if (identical(agg_function, prod)) {
    n_count <- children_dt[, .N, by = by_id_cols]
    sf_dt <- merge(sf_dt, n_count, by = by_id_cols, all = T)
  }
  for (col in 1:length(value_cols)) {
    sf_dt[, scaling_factor_value_cols[col] := get(value_cols[col]) / get(agg_value_cols[col])]
    if (identical(agg_function, prod)) {
      sf_dt[, scaling_factor_value_cols[col] := get(scaling_factor_value_cols[col]) ^ (1 / N)]
    }
  }
  sf_dt[, c(cols, value_cols, agg_value_cols) := NULL]
  if (col_type == "interval") sf_dt[, c(col_stem) := NULL]
  if (identical(agg_function, prod)) sf_dt[, N := NULL]

  # determine which common intervals the original dataset maps to
  scalar_by_id_cols <- copy(by_id_cols)
  if (collapse_interval_cols) {
    subtree_dt <- dt[get(col_stem) %in% c(parent, children)]
    for (stem in interval_id_cols_stems[interval_id_cols_stems != col_stem]) {
      common_intervals <- identify_common_intervals(
        dt = subtree_dt,
        id_cols = id_cols,
        col_stem = stem,
        include_missing = TRUE
      )
      subtree_dt <- merge_common_intervals(subtree_dt, common_intervals, stem)
      data.table::setnames(subtree_dt, c("common_start", "common_end"),
                           paste0("common_", stem, "_", c("start", "end")))

      # set up scalars for later merge
      data.table::setnames(sf_dt, paste0(stem, "_", c("start", "end")),
                           paste0("common_", stem, "_", c("start", "end")))
      scalar_by_id_cols[scalar_by_id_cols %in% paste0(stem, "_", c("start", "end"))] <-
        paste0("common_", stem, "_", c("start", "end"))
    }
    children_dt <- subtree_dt[get(col_stem) %in% children] # uncollapsed data
  }

  # calculate scaled child node values
  scaled_dt <- merge(children_dt, sf_dt, by = scalar_by_id_cols, all = T)
  for (col in 1:length(value_cols)) {
    scaled_dt[, scaled_value_cols[col] := get(value_cols[col]) * get(scaling_factor_value_cols[col])]
  }
  scaled_dt <- scaled_dt[, c(id_cols, scaled_value_cols), with = F]
  return(scaled_dt)
}
