import { useTranslation } from 'react-i18next';
import { Grid, Typography, Divider, Box } from '@mui/material';

export const Features = () => {
  const { t } = useTranslation();
  return (
    <Grid container={true} spacing={2} paddingTop={4}>
      <Grid item={true} xs={12}>
        <Divider />
        <Box p={2}>
          <Typography variant="h5" align={'center'}>
            {t('features.title')}
          </Typography>
        </Box>
      </Grid>
    </Grid>
  );
};

