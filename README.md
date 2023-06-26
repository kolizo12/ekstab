# ekstabbank
This terraform template is used to create a EKS cluster using an existing VPC with public and private subnet
This needs the VPC_ID passed and the EKS NAME passed into this module to work

This is done in the 
`/root/eks.tf`
You will need to add this manaully
Here the defaults are set to `testing` for eks name and vpc_id `vpc-0dd2a14e052b80c54`

This creates a private subnet per AZ and nat gateway with the assiocated routes.


