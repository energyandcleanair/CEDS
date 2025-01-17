# ------------------------------------------------------------------------------
# Program Name: G1.2.grid_subVOC_emissions.R
# Authors: Leyang Feng, Caleb Braun
# Date Last Updated: Feb 7, 2019
# Program Purpose: Grid aggregated emissions into NetCDF grids for subVOCs
# Input Files:  MED_OUT:    CEDS_NMVOC_emissions_by_country_CEDS_sector_[CEDS_version].csv
# Output Files: MED_OUT:    gridded-emissions/CEDS_[VOCID]_anthro_[year]_0.5_[CEDS_version].nc
#                           gridded-emissions/CEDS_[VOCID]_anthro_[year]_0.5_[CEDS_version].csv
#               DIAG_OUT:   G.[VOCID]_bulk_emissions_checksum_comparison_per.csv
#                           G.[VOCID]_bulk_emissions_checksum_comparison_diff.csv
# ------------------------------------------------------------------------------


# ------------------------------------------------------------------------------
# 0. Read in global settings and headers
# Define PARAM_DIR as the location of the CEDS "parameters" directory, relative
# to the "input" directory.
PARAM_DIR <- if("input" %in% dir()) "code/parameters/" else "../code/parameters/"

# Read in universal header files, support scripts, and start logging
headers <- c( 'data_functions.R', 'gridding_functions.R', 'nc_generation_functions.R' )
log_msg <- "VOC speciation gridding "
source( paste0( PARAM_DIR, "header.R" ) )
initialize( "G1.2.grid_subVOC_emissions.R", log_msg, headers )


# ------------------------------------------------------------------------------
# 0.5 Initialize gridding setups

# Define emissions species variable
args_from_makefile <- commandArgs( TRUE )
VOC_em <- args_from_makefile[ 1 ]
if ( is.na( VOC_em ) ) VOC_em <- "VOC01"

em <- 'NMVOC'

# Set up directories
output_dir          <- filePath( "MED_OUT",  "gridded-emissions/",     extension = "" )
proxy_dir           <- filePath( "GRIDDING", "proxy/",                 extension = "" )
proxy_backup_dir    <- filePath( "GRIDDING", "proxy-backup/",          extension = "" )
mask_dir            <- filePath( "GRIDDING", "mask/",                  extension = "" )
seasonality_dir     <- filePath( "GRIDDING", "seasonality/",           extension = "" )
final_emissions_dir <- filePath( "FIN_OUT",  "current-versions/",      extension = "" )

# Initialize the gridding parameters
gridding_initialize( grid_resolution = 0.5,
                     start_year = 1750,
                     end_year = end_year,
                     load_masks = T,
                     load_seasonality_profile = T )


# ------------------------------------------------------------------------------
# 1. Read in files

# Read in the emission data; the flag GRID_SUBREGIONS is set in global_settings.R
# and indicates whether or not to use subregional emissions data.
if ( GRID_SUBREGIONS ) {
  pattern <- paste0( ".*", em, '_subnational.*' )
} else {
  pattern <- paste0( ".*_", em, '_emissions_by_country_CEDS_sector.*' )
}

target_filename <- list.files( final_emissions_dir, pattern )
target_filename <- tools::file_path_sans_ext( target_filename )
stopifnot( length( target_filename ) == 1 )
emissions <- readData( "FIN_OUT", domain_extension = "current-versions/", target_filename )

# If defined, remove emissions from one iso from gridding
if ( grid_remove_iso != "" ) {
  emissions <- dplyr::mutate_at( emissions, vars( all_of(X_extended_years) ),
                                 list( ~ifelse( iso == grid_remove_iso, 0, . )))
}

# Read in mapping files
# the location index indicates the location of each region mask in the 'world' matrix
location_index             <- readData( 'GRIDDING', domain_extension = 'gridding_mappings/', 'country_location_index_05', meta = F )
ceds_gridding_mapping      <- readData( 'GRIDDING', domain_extension = 'gridding_mappings/', 'CEDS_sector_to_gridding_sector_mapping', meta = F )
proxy_mapping              <- readData( 'GRIDDING', domain_extension = 'gridding_mappings/', 'proxy_mapping', meta = F )
seasonality_mapping        <- readData( 'GRIDDING', domain_extension = 'gridding_mappings/', 'seasonality_mapping', meta = F )
proxy_substitution_mapping <- readData( 'GRIDDING', domain_extension = 'gridding_mappings/', 'proxy_subsititution_mapping', meta = F )
sector_name_mapping        <- readData( 'GRIDDING', domain_extension = 'gridding_mappings/', 'CEDS_gridding_sectors', meta = F )
sector_name_mapping        <- unique( sector_name_mapping[ , c( 'CEDS_fin_sector', 'CEDS_fin_sector_short' ) ] )
VOC_ratios                 <- readData( 'GRIDDING', domain_extension = "gridding_mappings/", 'VOC_ratio_AllSectors', meta = F )
VOC_names                  <- readData( 'GRIDDING', domain_extension = "gridding_mappings/", 'VOC_id_name_mapping', meta = F )

# ------------------------------------------------------------------------------
# 2. Pre-processing

# a) Convert the emission data from CEDS working sectors to CEDS level 1 gridding sector
# b) Drop non-matched sectors
# c) Aggregate the emissions at the gridding sectors
# d) Fix names
# e) Remove AIR sector in data
gridding_emissions <- ceds_gridding_mapping %>%
  dplyr::select( CEDS_working_sector, CEDS_int_gridding_sector_short ) %>%
  dplyr::inner_join( emissions, by = c( 'CEDS_working_sector' = 'sector' ) ) %>%
  dplyr::filter( !is.na( CEDS_int_gridding_sector_short ) ) %>%
  dplyr::group_by( iso, CEDS_int_gridding_sector_short ) %>%
  dplyr::summarise_at( paste0( 'X', year_list ), sum ) %>%
  dplyr::ungroup() %>%
  dplyr::rename( sector = CEDS_int_gridding_sector_short ) %>%
  dplyr::filter( sector != 'AIR' ) %>%
  dplyr::arrange( sector, iso ) %>%
  as.data.frame()

VOC_ratios <- dplyr::select( VOC_ratios, iso, sector, !!VOC_em )

# apply VOC ratio (multiply all years by ratio column)
gridding_emissions <- gridding_emissions %>%
    dplyr::inner_join( VOC_ratios, by = c( 'iso', 'sector' ) ) %>%
    dplyr::mutate_at( vars( num_range( 'X', year_list ) ), `*`, .[[VOC_em]]) %>%
    dplyr::select( -all_of(VOC_em) )

proxy_files <- list( primary = list.files( proxy_dir ), backup = list.files( proxy_backup_dir ) )

#Extend to last year
proxy_mapping <- extendProxyMapping( proxy_mapping )
seasonality_mapping <- extendSeasonalityMapping( seasonality_mapping )

# ------------------------------------------------------------------------------
# 3. Gridding and writing output data

# For now, the gridding routine uses nested for loops to go through every years
# gases and sectors. May consider to take away for loop for sectors and keep year loops
# for future parallelization

printLog( paste( 'Start', VOC_em, 'gridding for each year' ) )

for ( year in year_list ) {
  # grid one years emissions for subVOCs
  int_grids_list <- grid_one_year( year, em, grid_resolution, gridding_emissions, location_index,
                                   proxy_mapping, proxy_substitution_mapping, proxy_files )

  # generate nc file for gridded one years subVOC emissions,
  # a checksum file is also generated along with the nc file
  # which summarize the emissions in mass by sector by month.
  generate_final_grids_nc_subVOC( int_grids_list, output_dir, grid_resolution, year, em = 'NMVOC',
                                  VOC_em = VOC_em, VOC_names, sector_name_mapping, seasonality_mapping )
}


# -----------------------------------------------------------------------------
# 4. Diagnostic: checksum

# The checksum process uses the checksum files generated along the nc file
# for all gridding years then compare with the input emissions at
# final gridding sector level for each year.
# The comparisons are done in two ways: absolute difference and percentage difference

printLog( 'Start checksum check' )

# calculate global total emissions by sector by year
gridding_emissions_fin <- ceds_gridding_mapping %>%
    dplyr::select( CEDS_int_gridding_sector_short, CEDS_final_gridding_sector_short ) %>%
    dplyr::distinct() %>%
    dplyr::right_join( gridding_emissions, by = c( 'CEDS_int_gridding_sector_short' = 'sector' ) ) %>%
    dplyr::group_by( CEDS_final_gridding_sector_short ) %>%
    dplyr::summarise_at( vars( starts_with( 'X' ) ), sum ) %>%
    dplyr::ungroup() %>%
    dplyr::rename( sector = CEDS_final_gridding_sector_short ) %>%
    dplyr::arrange( sector )

# consolidate different checksum files to have total emissions by sector by year
checksum_df <- list.files( output_dir, paste0( '_', em, '_anthro.*[.]csv' ), full.names = TRUE ) %>%
    lapply( read.csv ) %>%
    dplyr::bind_rows() %>%
    dplyr::group_by( sector, year ) %>%
    dplyr::summarise( value = sum( value ) ) %>%
    dplyr::ungroup() %>%
    tidyr::spread( year, value ) %>%
    dplyr::rename_all( make.names ) %>%
    dplyr::arrange( sector )

# comparison
X_year_list <- paste0( 'X', year_list )
diag_diff_df <- cbind( checksum_df$sector, abs( gridding_emissions_fin[ X_year_list ] - checksum_df[ X_year_list ] ) )
diag_per_df <- cbind( checksum_df$sector, ( diag_diff_df[ X_year_list ] / gridding_emissions_fin[ X_year_list ] ) * 100 )
diag_per_df[ is.nan.df( diag_per_df ) ] <- NA


# -----------------------------------------------------------------------------
# 5. Write-out and Stop

out_name <- paste0( 'G.', VOC_em, '_bulk_emissions_checksum_comparison_diff' )
writeData( diag_diff_df, "DIAG_OUT", out_name )
out_name <- paste0( 'G.', VOC_em, '_bulk_emissions_checksum_comparison_per' )
writeData( diag_per_df, "DIAG_OUT", out_name )

logStop()
