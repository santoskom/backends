require('dotenv').config();
const express = require('express');
const cors = require('cors');
const twilio = require('twilio');
const { pool, testConnection } = require('./db');
const { sendEmail } = require('./services/mailer');
// const cors = require('cors');
const app = express();

const PORT = process.env.PORT || 5000;
app.use(cors({
  origin: '*', // ou l'URL de ton frontend
  credentials: true,
}));
// Middlewares
app.use(cors());
app.use(express.json());

// Routes
const authRoutes = require('./route/sendMail');
app.use('/api', authRoutes);
console.log('Route /api (sendMail) chargée');

const verifyRoute = require('./auth/verify');
app.use('/api/verify', verifyRoute);
console.log('Route /api/auth/verify chargée');

const loginRoute = require('./auth/login');
app.use('/api/auth', loginRoute); 
console.log('Route /api/auth/login chargée');

const deleteRoute = require('./auth/delete');
app.use('/api/delete', deleteRoute); 
console.log('Route delete  chargée');



const vaccinehistoryRoute = require('./route/vaccine-history');
app.use('/api/vaccine-history', vaccinehistoryRoute); 
console.log('Route /api/route/vaccine-history page ');

const vaccinationRoutes = require('./route/addvaccin');             
app.use('/api/vaccinations', vaccinationRoutes);

const registerRoute = require('./auth/register');
app.use('/api/auth/register', registerRoute);
console.log('Route /api/auth/register chargée');

const userTypesRoute = require('./auth/usertypes');
app.use('/api/auth/usertypes', userTypesRoute);
console.log('Route /api/auth/usertypes chargée');

const centerRoute = require('./health/centers');
app.use('/api/health/centers', centerRoute);


// citoyen compte 
const vaccinationHistoryRoute = require("./route/vaccinationHistory");
app.use("/api/vaccinations", vaccinationHistoryRoute);


const upcomingVaccinesRoute = require("./route/upcomingVaccines");
app.use("/api/upcoming", upcomingVaccinesRoute);

const statsRouter = require("./route/stats");
app.use("/api/stats", statsRouter);

const familyMembersRouter = require('./route/familyMembers');
app.use('/api/family-members', familyMembersRouter);

const familyMemberssRouter = require('./route/familyMemberss');
app.use('/api/family-memberss', familyMemberssRouter);


const userAccountRoutes = require('./route/userAccount');
app.use('/api/user', userAccountRoutes);

const remindersRoutes = require('./route/reminders');
app.use('/api/reminders', remindersRoutes);

const statsRoutes = require('./route/statistics');
app.use('/api/statistics', statsRoutes);

const statRoutes = require('./route/index1');
app.use('/api/statistic', statRoutes);
// end citoyen



//professionnel

const profAccountRoutes = require('./route/profAccount');
app.use('/api/users', profAccountRoutes);

const reminderRoutes = require('./route/calendar');
app.use('/api/calendar', reminderRoutes);

const inventoryRoutes = require('./route/inventory');
app.use('/api/inventory', inventoryRoutes);

const adverseEffectsRoutes = require('./route/adverseEffects');
app.use('/api/adverse-effects', adverseEffectsRoutes);

const sideEffectsRoutes = require('./route/sideEffects');
app.use('/api/side-effects', sideEffectsRoutes);

const dashboardRoutes = require('./route/dashboard');
app.use('/api/dashboard', dashboardRoutes);


const delete1Route = require('./auth/delete1');
app.use('/api/delete1', delete1Route); 
console.log('Route delete  chargée');


app.get('/', (req, res) => {
  res.send('Bienvenue sur l’API Vaccination !');
});
//end professionnel
// Démarrage serveur
app.listen(PORT, () => {
  console.log(`✅ Serveur Node.js en écoute sur http://localhost:${PORT}`);
});
